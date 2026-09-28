CREATE TABLE IF NOT EXISTS public.productos (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    nombre text NOT NULL UNIQUE,
    categoria text NOT NULL,
    descripcion text NOT NULL DEFAULT '',
    precio integer NOT NULL CHECK (precio >= 0),
    imagen_url text NOT NULL,
    stock integer NOT NULL DEFAULT 0 CHECK (stock >= 0),
    activo boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.productos
    ADD COLUMN IF NOT EXISTS categoria text NOT NULL DEFAULT 'Cabello',
    ADD COLUMN IF NOT EXISTS descripcion text NOT NULL DEFAULT '',
    ADD COLUMN IF NOT EXISTS precio integer NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS imagen_url text NOT NULL DEFAULT '',
    ADD COLUMN IF NOT EXISTS stock integer NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS activo boolean NOT NULL DEFAULT true,
    ADD COLUMN IF NOT EXISTS created_at timestamptz NOT NULL DEFAULT now(),
    ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();

ALTER TABLE public.productos ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Public can view active products" ON public.productos;
CREATE POLICY "Public can view active products"
ON public.productos
FOR SELECT
TO anon, authenticated
USING (activo = true);

DROP POLICY IF EXISTS "Admins manage products" ON public.productos;
CREATE POLICY "Admins manage products"
ON public.productos
FOR ALL
TO authenticated
USING ((auth.jwt() -> 'user_metadata' ->> 'role') = 'admin')
WITH CHECK ((auth.jwt() -> 'user_metadata' ->> 'role') = 'admin');

INSERT INTO public.productos
    (nombre, categoria, descripcion, precio, imagen_url, stock, activo)
SELECT seed.nombre, seed.categoria, seed.descripcion, seed.precio,
       seed.imagen_url, seed.stock, seed.activo
FROM (VALUES
    (
        'Pomada Premium',
        'Cabello',
        'Brillo natural, textura moldeable y acabado profesional.',
        35000,
        'https://images.unsplash.com/photo-1621607512214-68297480165e?auto=format&fit=crop&w=900&q=85',
        10,
        true
    ),
    (
        'Aceite para Barba',
        'Barba',
        'Nutre, suaviza y deja una fragancia elegante durante todo el día.',
        28000,
        'https://images.unsplash.com/photo-1556228578-0d85b1a4d571?auto=format&fit=crop&w=900&q=85',
        10,
        true
    ),
    (
        'Kit Barber',
        'Kits',
        'Pomada, aceite y peine premium para mantener tu estilo.',
        60000,
        'https://images.unsplash.com/photo-1585747860715-2ba37e788b70?auto=format&fit=crop&w=900&q=85',
        5,
        true
    )
) AS seed(nombre, categoria, descripcion, precio, imagen_url, stock, activo)
WHERE NOT EXISTS (
    SELECT 1
    FROM public.productos AS producto
    WHERE producto.nombre = seed.nombre
);

CREATE TABLE IF NOT EXISTS public.resenas (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    cita_id uuid NOT NULL UNIQUE REFERENCES public.citas(id) ON DELETE CASCADE,
    barbero_id uuid NOT NULL REFERENCES public.barberos(id),
    cliente_nombre text NOT NULL,
    calificacion integer NOT NULL CHECK (calificacion BETWEEN 1 AND 5),
    comentario text NOT NULL DEFAULT '',
    aprobada boolean NOT NULL DEFAULT false,
    created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.resenas ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Public can view approved reviews" ON public.resenas;
CREATE POLICY "Public can view approved reviews"
ON public.resenas
FOR SELECT
TO anon, authenticated
USING (aprobada = true);

DROP POLICY IF EXISTS "Admins manage reviews" ON public.resenas;
CREATE POLICY "Admins manage reviews"
ON public.resenas
FOR ALL
TO authenticated
USING ((auth.jwt() -> 'user_metadata' ->> 'role') = 'admin')
WITH CHECK ((auth.jwt() -> 'user_metadata' ->> 'role') = 'admin');

CREATE OR REPLACE FUNCTION public.crear_resena_cita(
    p_cita_id uuid,
    p_telefono text,
    p_calificacion integer,
    p_comentario text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    cita public.citas%ROWTYPE;
    nueva_resena uuid;
BEGIN
    IF p_calificacion < 1 OR p_calificacion > 5 THEN
        RAISE EXCEPTION 'La calificación debe estar entre 1 y 5.';
    END IF;

    IF length(trim(COALESCE(p_comentario, ''))) > 500 THEN
        RAISE EXCEPTION 'El comentario no puede superar 500 caracteres.';
    END IF;

    SELECT *
    INTO cita
    FROM public.citas
    WHERE id = p_cita_id;

    IF NOT FOUND OR lower(cita.estado) <> 'atendida' THEN
        RAISE EXCEPTION 'Solo puedes calificar una cita atendida.';
    END IF;

    IF regexp_replace(COALESCE(cita.cliente_telefono, ''), '\D', '', 'g')
       <> regexp_replace(COALESCE(p_telefono, ''), '\D', '', 'g') THEN
        RAISE EXCEPTION 'El teléfono no coincide con el de la reserva.';
    END IF;

    INSERT INTO public.resenas (
        cita_id,
        barbero_id,
        cliente_nombre,
        calificacion,
        comentario
    )
    VALUES (
        cita.id,
        cita.barbero_id,
        cita.cliente_nombre,
        p_calificacion,
        trim(COALESCE(p_comentario, ''))
    )
    RETURNING id INTO nueva_resena;

    RETURN nueva_resena;
END;
$$;

REVOKE ALL ON FUNCTION public.crear_resena_cita(uuid, text, integer, text)
FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.crear_resena_cita(uuid, text, integer, text)
TO anon, authenticated;
