CREATE OR REPLACE FUNCTION public.listar_barberos_activos()
RETURNS TABLE (id uuid, nombre text)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT b.id, b.nombre
    FROM public.barberos AS b
    WHERE b.activo IS TRUE
    ORDER BY b.nombre;
$$;

REVOKE ALL ON FUNCTION public.listar_barberos_activos() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.listar_barberos_activos() TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.obtener_horarios_ocupados(
    p_barbero_id uuid,
    p_fecha date
)
RETURNS TABLE (hora text)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT c.hora::text
    FROM public.citas AS c
    WHERE c.barbero_id = p_barbero_id
      AND c.fecha = p_fecha
      AND lower(COALESCE(c.estado, '')) <> 'cancelada'
    ORDER BY c.hora;
$$;

REVOKE ALL ON FUNCTION public.obtener_horarios_ocupados(uuid, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.obtener_horarios_ocupados(uuid, date)
TO anon, authenticated;

GRANT SELECT ON TABLE public.resenas TO anon, authenticated;
ALTER TABLE public.resenas ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Public can view approved reviews" ON public.resenas;
CREATE POLICY "Public can view approved reviews"
ON public.resenas
FOR SELECT
TO anon, authenticated
USING (aprobada IS TRUE);

REVOKE SELECT ON TABLE public.citas FROM anon;
GRANT SELECT (id) ON TABLE public.citas TO anon;
GRANT INSERT (
    cliente_nombre,
    cliente_telefono,
    servicio,
    barbero_id,
    fecha,
    hora,
    estado
) ON TABLE public.citas TO anon;

DROP POLICY IF EXISTS "Public can read reservation ids" ON public.citas;
CREATE POLICY "Public can read reservation ids"
ON public.citas
FOR SELECT
TO anon
USING (true);

DROP POLICY IF EXISTS "Public can create reservations" ON public.citas;
CREATE POLICY "Public can create reservations"
ON public.citas
FOR INSERT
TO anon
WITH CHECK (
    estado = 'pendiente'
    AND fecha >= CURRENT_DATE
    AND EXISTS (
        SELECT 1
        FROM public.listar_barberos_activos() AS b
        WHERE b.id = barbero_id
    )
);
