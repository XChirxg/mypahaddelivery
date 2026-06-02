-- MyPahad Delivery Portal Database Integration & RLS Setup
-- Copy and execute this SQL script in your Supabase SQL Editor (on the Leads DB project 'rcyvtdmvimqvsrglrnwv')

-- =====================================================================
-- STEP 1: Create the drivers table (for local profile tracking & RLS)
-- =====================================================================
CREATE TABLE IF NOT EXISTS public.drivers (
  id uuid PRIMARY KEY DEFAULT auth.uid(), -- matches Supabase auth.users id
  name text NOT NULL,
  phone text NOT NULL,
  area_id uuid NOT NULL,
  is_approved boolean DEFAULT false,
  created_at timestamp with time zone DEFAULT now()
);

-- Enable RLS on drivers
ALTER TABLE public.drivers ENABLE ROW LEVEL SECURITY;

-- Policy: Allow public anonymous inserts (needed for signup)
CREATE POLICY "Allow public driver signup" 
ON public.drivers 
FOR INSERT 
TO public 
WITH CHECK (true);

-- Policy: Allow drivers to view and update their own profile
CREATE POLICY "Allow drivers to manage their own profile" 
ON public.drivers 
FOR ALL 
TO authenticated 
USING (id = auth.uid()) 
WITH CHECK (id = auth.uid());


-- =====================================================================
-- STEP 2: Create the delivery table (for unassigned / assigned runs)
-- =====================================================================
CREATE TABLE IF NOT EXISTS public.delivery (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  order_id uuid REFERENCES public.orders(id) ON DELETE CASCADE,
  driver_id uuid, -- NULL when unassigned, matches driver user ID
  driver_name text,
  driver_phone text,
  area_id uuid, -- Represents the location/area of the business/order
  status text DEFAULT 'pending' CHECK (status IN ('pending', 'dispatched', 'delivered', 'cancelled')),
  created_at timestamp with time zone DEFAULT now(),
  updated_at timestamp with time zone DEFAULT now(),
  CONSTRAINT delivery_pkey PRIMARY KEY (id)
);

-- Enable RLS on delivery
ALTER TABLE public.delivery ENABLE ROW LEVEL SECURITY;

-- Policy: Allow public anonymous inserts (needed for the chatbot order flow)
CREATE POLICY "Allow chatbot to insert delivery requests" 
ON public.delivery 
FOR INSERT 
TO public 
WITH CHECK (true);

-- Policy: Allow authenticated approved drivers in the same area to select/view delivery requests
CREATE POLICY "Allow same area drivers to view delivery requests" 
ON public.delivery 
FOR SELECT 
TO authenticated 
USING (
  area_id = (SELECT area_id FROM public.drivers WHERE id = auth.uid() AND is_approved = true)
);

-- Policy: Allow authenticated approved drivers in the same area to update delivery records
-- (They can only accept if it is unassigned, or update it if it's already assigned to them)
CREATE POLICY "Allow same area drivers to update delivery records" 
ON public.delivery 
FOR UPDATE 
TO authenticated 
USING (
  area_id = (SELECT area_id FROM public.drivers WHERE id = auth.uid() AND is_approved = true)
  AND (driver_id IS NULL OR driver_id = auth.uid())
) 
WITH CHECK (
  driver_id = auth.uid()
);


-- =====================================================================
-- STEP 3: Configure Row-Level Security (RLS) on public.orders
-- =====================================================================
-- Enable RLS on orders
ALTER TABLE public.orders ENABLE ROW LEVEL SECURITY;

-- 1. DROP old policies if they exist to prevent conflicts
DROP POLICY IF EXISTS "Allow customers to insert their orders" ON public.orders;
DROP POLICY IF EXISTS "Allow authenticated drivers to view available orders" ON public.orders;
DROP POLICY IF EXISTS "Allow drivers to update assigned orders" ON public.orders;
DROP POLICY IF EXISTS "Allow drivers to view same area orders" ON public.orders;

-- 2. Policy: Allow customers (anonymous/public) to insert new orders (needed for the chatbot)
CREATE POLICY "Allow customers to insert their orders" 
ON public.orders 
FOR INSERT 
TO public 
WITH CHECK (true);

-- 3. Policy: Allow authenticated drivers to view orders in their service area
-- (Queries the delivery table to check if there is a matching delivery row for their area)
CREATE POLICY "Allow drivers to view same area orders" 
ON public.orders 
FOR SELECT 
TO authenticated 
USING (
  id IN (
    SELECT order_id 
    FROM public.delivery 
    WHERE area_id = (SELECT area_id FROM public.drivers WHERE id = auth.uid() AND is_approved = true)
  )
);


-- =====================================================================
-- STEP 4: Create Database Status Sync Trigger
-- =====================================================================
-- Create trigger function to automatically sync status changes from the
-- delivery table to the orders table, and append delivery assignment details
CREATE OR REPLACE FUNCTION public.sync_order_status_from_delivery()
RETURNS TRIGGER AS $$
BEGIN
  UPDATE public.orders
  SET 
    status = NEW.status,
    notes = CASE 
      WHEN NEW.status = 'dispatched' THEN 
        COALESCE(notes, '') || E'\n\n[Delivery Assigned: ' || NEW.driver_name || ' (' || NEW.driver_phone || ')]'
      ELSE notes
    END,
    updated_at = NEW.updated_at
  WHERE id = NEW.order_id;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Bind trigger to the delivery table
DROP TRIGGER IF EXISTS trigger_sync_order_status ON public.delivery;
CREATE TRIGGER trigger_sync_order_status
AFTER UPDATE OF status ON public.delivery
FOR EACH ROW
EXECUTE FUNCTION public.sync_order_status_from_delivery();
