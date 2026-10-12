-- COE Nómina 2.0 · Paso 2 (correr SOLO cuando ya uses la app nueva; la v1 deja de funcionar)
-- Cierra la lectura directa con la llave pública de las tablas de nómina que tienen
-- salarios, RFC, NSS y CLABE. La app nueva lee todo mediante funciones con sesión.
alter table public.nom_empleados enable row level security;
alter table public.nom_asistencias enable row level security;
alter table public.nom_periodos enable row level security;
alter table public.nom_descuentos enable row level security;
alter table public.nom_descuento_pagos enable row level security;
alter table public.nom_pdf_mapeo enable row level security;
alter table public.nom_historial enable row level security;
alter table public.nom_rrhh_usuarios enable row level security;
