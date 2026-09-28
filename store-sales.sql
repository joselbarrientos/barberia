CREATE TABLE IF NOT EXISTS public.pedidos_tienda (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    cliente_nombre text NOT NULL DEFAULT 'Cliente web',
    cliente_telefono text NOT NULL DEFAULT '',
    total integer NOT NULL DEFAULT 0 CHECK (total >= 0),
    estado text NOT NULL DEFAULT 'pendiente'
        CHECK (estado IN ('pendiente', 'vendida', 'cancelada')),
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.pedido_detalles (
    pedido_id uuid NOT NULL REFERENCES public.pedidos_tienda(id) ON DELETE CASCADE,
    producto_id uuid NOT NULL REFERENCES public.productos(id) ON DELETE RESTRICT,
    producto_nombre text NOT NULL,
    cantidad integer NOT NULL CHECK (cantidad > 0),
    precio_unitario integer NOT NULL CHECK (precio_unitario >= 0),
    PRIMARY KEY (pedido_id, producto_id)
);

ALTER TABLE public.pedidos_tienda ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pedido_detalles ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.pedidos_tienda, public.pedido_detalles
FROM anon, authenticated;
GRANT SELECT ON public.pedidos_tienda, public.pedido_detalles TO authenticated;

DROP POLICY IF EXISTS "Admins read store orders" ON public.pedidos_tienda;
CREATE POLICY "Admins read store orders"
ON public.pedidos_tienda
FOR SELECT
TO authenticated
USING ((auth.jwt() -> 'user_metadata' ->> 'role') = 'admin');

DROP POLICY IF EXISTS "Admins read store order details" ON public.pedido_detalles;
CREATE POLICY "Admins read store order details"
ON public.pedido_detalles
FOR SELECT
TO authenticated
USING (
    (auth.jwt() -> 'user_metadata' ->> 'role') = 'admin'
);

CREATE OR REPLACE FUNCTION public.crear_pedido_tienda(
    p_items jsonb,
    p_nombre text DEFAULT 'Cliente web',
    p_telefono text DEFAULT ''
)
RETURNS TABLE (pedido_id uuid, total integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_pedido_id uuid;
    v_total integer := 0;
    v_item record;
    v_producto public.productos%ROWTYPE;
BEGIN
    IF jsonb_typeof(p_items) IS DISTINCT FROM 'array' THEN
        RAISE EXCEPTION 'El pedido debe incluir entre 1 y 50 productos.';
    END IF;

    IF jsonb_array_length(p_items) = 0
       OR jsonb_array_length(p_items) > 50 THEN
        RAISE EXCEPTION 'El pedido debe incluir entre 1 y 50 productos.';
    END IF;

    IF length(trim(COALESCE(p_nombre, ''))) > 100
       OR length(trim(COALESCE(p_telefono, ''))) > 30 THEN
        RAISE EXCEPTION 'El nombre o el teléfono supera el máximo permitido.';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM jsonb_to_recordset(p_items) AS item(id uuid, cantidad integer)
        WHERE item.id IS NULL
           OR item.cantidad IS NULL
           OR item.cantidad < 1
           OR item.cantidad > 50
    ) THEN
        RAISE EXCEPTION 'El pedido contiene productos o cantidades no válidas.';
    END IF;

    INSERT INTO public.pedidos_tienda (cliente_nombre, cliente_telefono)
    VALUES (
        COALESCE(NULLIF(trim(p_nombre), ''), 'Cliente web'),
        COALESCE(trim(p_telefono), '')
    )
    RETURNING id INTO v_pedido_id;

    FOR v_item IN
        SELECT item.id, sum(item.cantidad)::integer AS cantidad
        FROM jsonb_to_recordset(p_items) AS item(id uuid, cantidad integer)
        GROUP BY item.id
        ORDER BY item.id
    LOOP
        SELECT *
        INTO v_producto
        FROM public.productos
        WHERE id = v_item.id
          AND activo IS TRUE
        FOR SHARE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Uno de los productos ya no está disponible.';
        END IF;

        IF v_item.cantidad > v_producto.stock THEN
            RAISE EXCEPTION 'Stock insuficiente para el producto "%".',
                v_producto.nombre;
        END IF;

        IF v_total::bigint + v_item.cantidad::bigint * v_producto.precio
           > 2147483647 THEN
            RAISE EXCEPTION 'El total del pedido excede el máximo permitido.';
        END IF;

        INSERT INTO public.pedido_detalles (
            pedido_id,
            producto_id,
            producto_nombre,
            cantidad,
            precio_unitario
        )
        VALUES (
            v_pedido_id,
            v_producto.id,
            v_producto.nombre,
            v_item.cantidad,
            v_producto.precio
        );

        v_total := v_total + (v_item.cantidad * v_producto.precio);
    END LOOP;

    UPDATE public.pedidos_tienda
    SET total = v_total
    WHERE id = v_pedido_id;

    RETURN QUERY SELECT v_pedido_id, v_total;
END;
$$;

REVOKE ALL ON FUNCTION public.crear_pedido_tienda(jsonb, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.crear_pedido_tienda(jsonb, text, text)
TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.confirmar_venta_pedido(p_pedido_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_estado text;
    v_detalle record;
    v_stock integer;
BEGIN
    IF (auth.jwt() -> 'user_metadata' ->> 'role') IS DISTINCT FROM 'admin' THEN
        RAISE EXCEPTION 'Solo un administrador puede confirmar una venta.';
    END IF;

    SELECT estado
    INTO v_estado
    FROM public.pedidos_tienda
    WHERE id = p_pedido_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontró el pedido.';
    END IF;

    IF v_estado <> 'pendiente' THEN
        RAISE EXCEPTION 'El pedido ya no está pendiente.';
    END IF;

    FOR v_detalle IN
        SELECT producto_id, producto_nombre, cantidad
        FROM public.pedido_detalles
        WHERE pedido_id = p_pedido_id
        ORDER BY producto_id
    LOOP
        SELECT stock
        INTO v_stock
        FROM public.productos
        WHERE id = v_detalle.producto_id
        FOR UPDATE;

        IF NOT FOUND OR v_stock < v_detalle.cantidad THEN
            RAISE EXCEPTION 'No hay stock suficiente para "%".',
                v_detalle.producto_nombre;
        END IF;

        UPDATE public.productos
        SET stock = stock - v_detalle.cantidad,
            updated_at = now()
        WHERE id = v_detalle.producto_id;
    END LOOP;

    UPDATE public.pedidos_tienda
    SET estado = 'vendida'
    WHERE id = p_pedido_id;
END;
$$;

REVOKE ALL ON FUNCTION public.confirmar_venta_pedido(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.confirmar_venta_pedido(uuid)
TO authenticated;

CREATE OR REPLACE FUNCTION public.cancelar_pedido_tienda(p_pedido_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF (auth.jwt() -> 'user_metadata' ->> 'role') IS DISTINCT FROM 'admin' THEN
        RAISE EXCEPTION 'Solo un administrador puede cancelar un pedido.';
    END IF;

    UPDATE public.pedidos_tienda
    SET estado = 'cancelada'
    WHERE id = p_pedido_id
      AND estado = 'pendiente';

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El pedido no existe o ya no está pendiente.';
    END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.cancelar_pedido_tienda(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.cancelar_pedido_tienda(uuid)
TO authenticated;
