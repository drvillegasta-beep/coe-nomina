-- ═══════════════════════════════════════════════════════════════════════
-- COE Nómina 2.0 · Base de datos (aditiva: no borra ni altera datos de la v1)
-- Supabase coe-quirofano (ckjkdenwqicdjvodflba)
-- Acceso: mismos usuarios de COE Finanzas (fin_usuarios: usuario + contraseña; PIN = firma).
-- Lectura y escritura SOLO mediante funciones con token de sesión (RLS cerrado en tablas nuevas).
-- Información sensible (salarios, banco, bajas, borrar o corregir registros, reabrir nómina,
-- reglas de cálculo): doble PIN = quien opera + Director General (o, si opera el Director,
-- un segundo usuario con nivel de captura, p. ej. la Contadora).
-- ═══════════════════════════════════════════════════════════════════════

-- 1. Empleados: columnas nuevas -------------------------------------------
alter table public.nom_empleados add column if not exists salario_diario numeric;
alter table public.nom_empleados add column if not exists sede text default 'Tacámbaro';
alter table public.nom_empleados add column if not exists horario jsonb;
alter table public.nom_empleados add column if not exists controla_asistencia boolean default true;
alter table public.nom_empleados add column if not exists retener_isr boolean default false;
alter table public.nom_empleados add column if not exists retener_imss boolean default false;
alter table public.nom_empleados add column if not exists fecha_baja date;
alter table public.nom_empleados add column if not exists motivo_baja text;
alter table public.nom_empleados add column if not exists curp text;
alter table public.nom_empleados add column if not exists telefono text;
alter table public.nom_empleados add column if not exists email text;
alter table public.nom_empleados add column if not exists forma_pago text default 'transferencia';
alter table public.nom_empleados add column if not exists notas text;
alter table public.nom_empleados add column if not exists updated_at timestamptz;
update public.nom_empleados set salario_diario = round(salario_base / 15.0, 2)
 where salario_diario is null and salario_base is not null;
update public.nom_empleados set horario = '{"entrada":"09:00","salida":"18:00","comida_min":60,"dias":[1,2,3,4,5,6]}'::jsonb
 where horario is null;

alter table public.nom_pdf_mapeo add column if not exists bio_id text;

-- 2. Tablas nuevas ----------------------------------------------------------
create table if not exists public.nom_config (
  clave text primary key, valor jsonb not null, updated_at timestamptz default now(), updated_by text);

create table if not exists public.nom_permisos (
  usuario_id uuid primary key references public.fin_usuarios(id), nivel int not null check (nivel between 0 and 3),
  updated_at timestamptz default now());

create table if not exists public.nom_sesiones (
  token text primary key, usuario_id uuid not null references public.fin_usuarios(id),
  creado timestamptz default now(), expira timestamptz not null, agente text);

create table if not exists public.nom_importaciones (
  id uuid primary key default gen_random_uuid(), archivo text, url text, sha256 text,
  desde date, hasta date, registros int, nuevos int, subido_por uuid, subido_at timestamptz default now());

create table if not exists public.nom_checadas (
  id uuid primary key default gen_random_uuid(),
  empleado_id uuid references public.nom_empleados(id), bio_id text, bio_nombre text,
  fecha date not null, hora time not null, estado_bio text,
  origen text not null default 'biometrico' check (origen in ('biometrico','manual')),
  importacion_id uuid references public.nom_importaciones(id), nota text,
  creada_por uuid, created_at timestamptz default now(),
  anulada boolean default false, anulada_por uuid, anulada_at timestamptz, anulada_motivo text);
create unique index if not exists nom_checadas_bio_uk on public.nom_checadas (bio_id, fecha, hora) where origen = 'biometrico';
create index if not exists nom_checadas_emp_fecha on public.nom_checadas (empleado_id, fecha);

create table if not exists public.nom_incidencias (
  id uuid primary key default gen_random_uuid(),
  empleado_id uuid not null references public.nom_empleados(id),
  fecha date not null, fecha_fin date,
  tipo text not null check (tipo in ('justificada','permiso_con_goce','permiso_sin_goce','incapacidad','vacaciones',
        'retardo_justificado','falla_checador','horas_extra','festivo_laborado','descanso_laborado','suspension','dia_libre')),
  con_goce boolean default true, horas numeric, nota text not null, evidencia_url text,
  creada_por uuid, created_at timestamptz default now(), nomina_id uuid,
  anulada boolean default false, anulada_por uuid, anulada_at timestamptz, anulada_motivo text);
create index if not exists nom_incidencias_emp_fecha on public.nom_incidencias (empleado_id, fecha);

create table if not exists public.nom_movimientos (
  id uuid primary key default gen_random_uuid(),
  empleado_id uuid not null references public.nom_empleados(id), fecha date not null,
  tipo text not null check (tipo in ('percepcion','deduccion')),
  concepto text not null, monto numeric not null check (monto > 0), gravable boolean default true, nota text,
  creada_por uuid, created_at timestamptz default now(), nomina_id uuid,
  anulada boolean default false, anulada_por uuid, anulada_at timestamptz, anulada_motivo text);

create sequence if not exists public.nom_nominas_folio_seq;
create table if not exists public.nom_nominas (
  id uuid primary key default gen_random_uuid(),
  folio text unique default ('NOM-' || lpad(nextval('public.nom_nominas_folio_seq')::text, 5, '0')),
  tipo text not null default 'ordinaria' check (tipo in ('ordinaria','aguinaldo','finiquito','extraordinaria')),
  sede text not null default 'Tacámbaro' check (sede in ('Tacámbaro','Morelia')),
  fecha_ini date not null, fecha_fin date not null, fecha_pago date not null,
  estado text not null default 'borrador' check (estado in ('borrador','calculada','observada','revisada','autorizada','cancelada')),
  percepciones numeric default 0, deducciones numeric default 0, neto numeric default 0, empleados int default 0,
  calculada_por uuid, calculada_at timestamptz,
  revisada_por uuid, revisada_at timestamptz, revision_nota text,
  autorizada_por uuid, autorizada_at timestamptz,
  cancelada_por uuid, cancelada_at timestamptz, cancelada_motivo text,
  notas text, creada_por uuid, created_at timestamptz default now());

create table if not exists public.nom_recibos (
  id uuid primary key default gen_random_uuid(),
  nomina_id uuid not null references public.nom_nominas(id) on delete cascade,
  empleado_id uuid not null references public.nom_empleados(id),
  detalle jsonb not null, percepciones numeric not null, deducciones numeric not null, neto numeric not null,
  egreso_id uuid, created_at timestamptz default now(), unique (nomina_id, empleado_id));

alter table public.nom_descuentos add column if not exists anulado boolean default false;
alter table public.nom_descuentos add column if not exists anulado_motivo text;
alter table public.nom_descuentos add column if not exists fecha_inicio date;
alter table public.nom_descuento_pagos add column if not exists nomina_id uuid references public.nom_nominas(id);
alter table public.nom_descuentos drop constraint if exists nom_descuentos_cuotas_total_check;
alter table public.nom_descuentos add constraint nom_descuentos_cuotas_total_check check (cuotas_total between 1 and 48);
alter table public.nom_descuentos drop constraint if exists nom_descuentos_tipo_check;
alter table public.nom_descuentos add constraint nom_descuentos_tipo_check
  check (tipo in ('prestamo','sancion','venta','faltante_caja','otro'));

-- RLS cerrado: nadie lee/escribe directo con la llave pública; todo pasa por funciones
alter table public.nom_config enable row level security;
alter table public.nom_permisos enable row level security;
alter table public.nom_sesiones enable row level security;
alter table public.nom_importaciones enable row level security;
alter table public.nom_checadas enable row level security;
alter table public.nom_incidencias enable row level security;
alter table public.nom_movimientos enable row level security;
alter table public.nom_nominas enable row level security;
alter table public.nom_recibos enable row level security;

-- Bitácora (misma bitácora inmutable de Finanzas: fin_log)
drop trigger if exists trg_audit on public.nom_empleados;
create trigger trg_audit after insert or update or delete on public.nom_empleados for each row execute function public.fin_audit();
drop trigger if exists trg_audit on public.nom_incidencias;
create trigger trg_audit after insert or update or delete on public.nom_incidencias for each row execute function public.fin_audit();
drop trigger if exists trg_audit on public.nom_movimientos;
create trigger trg_audit after insert or update or delete on public.nom_movimientos for each row execute function public.fin_audit();
drop trigger if exists trg_audit on public.nom_nominas;
create trigger trg_audit after insert or update or delete on public.nom_nominas for each row execute function public.fin_audit();
drop trigger if exists trg_audit on public.nom_checadas;
create trigger trg_audit after update or delete on public.nom_checadas for each row execute function public.fin_audit();
drop trigger if exists trg_audit on public.nom_descuentos;
create trigger trg_audit after insert or update or delete on public.nom_descuentos for each row execute function public.fin_audit();
drop trigger if exists trg_audit on public.nom_permisos;
create trigger trg_audit after insert or update or delete on public.nom_permisos for each row execute function public.fin_audit();
drop trigger if exists trg_audit on public.nom_config;
create trigger trg_audit after insert or update or delete on public.nom_config for each row execute function public.fin_audit();

-- 3. Configuración inicial (editable en la app, con doble PIN) ----------------
insert into public.nom_config (clave, valor) values
('reglas', '{
  "tolerancia_min": 10, "comida_tol_min": 5, "salida_anticipada_min": 15, "dedup_min": 3,
  "retardos_quitan_puntualidad": 1, "falta_quita_asistencia": true, "incompleta_quita_puntualidad": false,
  "retardos_por_falta": 0, "dias_quincena": 15, "descontar_septimo": false,
  "dias_aguinaldo": 15, "prima_vacacional": 25, "pagar_prima_al_gozar": true, "horas_jornada": 8,
  "prima_dominical": 25, "egreso_modo": "por_empleado", "festivos_extra": []
}'::jsonb),
('fiscal', '{
  "anio": 2026, "uma_diaria": 117.31, "uma_mensual": 3566.22, "salario_minimo": 315.04,
  "subsidio_pct_uma": 15.02, "subsidio_limite_mensual": 11492.66,
  "isr_mensual": [[0.01,0,1.92],[844.60,16.22,6.40],[7168.52,420.95,10.88],[12598.03,1011.68,16.00],[14644.65,1339.14,17.92],
                  [17533.65,1856.84,21.36],[35362.84,5665.16,23.52],[55736.69,10457.09,30.00],[106410.51,25659.23,32.00],
                  [141880.67,37009.69,34.00],[425642.00,133488.54,35.00]],
  "isr_quincenal": [[0.01,0,1.92],[416.71,7.95,6.40],[3537.16,207.75,10.88],[6216.16,499.20,16.00],[7225.96,660.75,17.92],
                  [8651.41,916.20,21.36],[17448.76,2795.25,23.52],[27501.61,5159.70,30.00],[52505.26,12660.75,32.00],
                  [70006.96,18261.30,34.00],[210020.71,65866.05,35.00]],
  "imss_obrero": {"excedente_3uma": 0.40, "prest_dinero": 0.25, "gastos_med_pens": 0.375, "invalidez_vida": 0.625, "cesantia_vejez": 1.125}
}'::jsonb)
on conflict (clave) do nothing;

-- 4. Sesión, niveles y firmas ----------------------------------------------
-- Niveles: 0 sin acceso · 1 consulta · 2 captura (importar, incidencias, calcular, revisar) · 3 Dirección (autorizar, permisos)
create or replace function public.nom__nivel(u public.fin_usuarios) returns int
language sql stable security definer set search_path to 'public' as $$
  select coalesce((select nivel from public.nom_permisos where usuario_id = u.id),
    case u.rol when 'admin' then 3 when 'contadora' then 2 when 'direccion' then 1 else 0 end)
$$;

create or replace function public.nom__sesion(p_token text, out u public.fin_usuarios, out nivel int, out err text)
language plpgsql security definer set search_path to 'public' as $$
declare s public.nom_sesiones;
begin
  select * into s from public.nom_sesiones where token = p_token and expira > now();
  if s.token is null then err := 'sesion'; return; end if;
  select * into u from public.fin_usuarios where id = s.usuario_id and activo;
  if u.id is null then err := 'sesion'; return; end if;
  nivel := public.nom__nivel(u);
  if nivel < 1 then err := 'sin_acceso'; return; end if;
  update public.nom_sesiones set expira = now() + interval '30 days' where token = p_token and expira < now() + interval '29 days';
  perform set_config('app.usuario_id', u.id::text, true);
  perform set_config('app.usuario_nombre', u.nombre, true);
end $$;

create or replace function public.nom__firmar(p_token text, p_pin text, p_nivel int, out u public.fin_usuarios, out nivel int, out err text)
language plpgsql security definer set search_path to 'public' as $$
declare s record; f record;
begin
  s := public.nom__sesion(p_token);
  if s.err is not null then err := s.err; return; end if;
  f := public.fin__firmar((s.u).id, p_pin);
  if f.err is not null then err := f.err; return; end if;
  u := s.u; nivel := s.nivel;
  if nivel < p_nivel then err := 'sin_permiso'; end if;
end $$;

-- Segunda firma para información sensible
create or replace function public.nom__segunda(p_u public.fin_usuarios, p_pin2 text, out d public.fin_usuarios, out err text)
language plpgsql security definer set search_path to 'public' as $$
declare dd record;
begin
  if coalesce(p_pin2, '') = '' then err := 'segunda_requerida'; return; end if;
  if p_u.rol <> 'admin' then
    dd := public.fin__director(p_u.id, p_pin2);
    if dd.err is not null then err := case dd.err when 'director_pin' then 'segunda_pin' else dd.err end; return; end if;
    d := dd.d; return;
  end if;
  select * into d from public.fin_usuarios x
   where x.activo and x.id <> p_u.id and public.nom__nivel(x) >= 2
     and x.pin_hash = encode(extensions.digest(p_pin2, 'sha256'), 'hex') limit 1;
  if d.id is null then
    update public.fin_usuarios set intentos_fallidos = intentos_fallidos + 1,
      bloqueado_hasta = case when intentos_fallidos + 1 >= 5 then now() + interval '5 minutes' end where id = p_u.id;
    err := 'segunda_pin';
  end if;
end $$;

create or replace function public.nom__log(p_tabla text, p_id uuid, p_accion text, p_desc text, p_datos jsonb)
returns void language sql security definer set search_path to 'public' as $$
  insert into public.fin_log (tabla, registro_id, usuario_id, usuario_nombre, accion, descripcion, despues, origen)
  values (p_tabla, p_id, nullif(current_setting('app.usuario_id', true), '')::uuid,
          coalesce(nullif(current_setting('app.usuario_nombre', true), ''), 'sin firma'), p_accion, p_desc, p_datos, 'nomina')
$$;

-- ¿La fecha ya está pagada en una nómina autorizada de ese empleado?
create or replace function public.nom__bloqueado(p_emp uuid, p_fecha date) returns boolean
language sql stable security definer set search_path to 'public' as $$
  select exists (select 1 from public.nom_recibos r join public.nom_nominas n on n.id = r.nomina_id
                  where r.empleado_id = p_emp and n.estado = 'autorizada' and n.tipo = 'ordinaria'
                    and p_fecha between n.fecha_ini and n.fecha_fin)
$$;

create or replace function public.nom_login(p_usuario text, p_password text, p_agente text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare r jsonb; u public.fin_usuarios; v_tok text; v_niv int;
begin
  r := public.fin_login(p_usuario, p_password);
  if not (r->>'ok')::boolean then return r; end if;
  if coalesce((r->>'debe_cambiar')::boolean, false) then return jsonb_build_object('ok', false, 'error', 'provisional'); end if;
  select * into u from public.fin_usuarios where id = (r->>'id')::uuid;
  v_niv := public.nom__nivel(u);
  if v_niv < 1 then return jsonb_build_object('ok', false, 'error', 'sin_acceso'); end if;
  delete from public.nom_sesiones where expira < now();
  v_tok := encode(extensions.gen_random_bytes(24), 'hex');
  insert into public.nom_sesiones (token, usuario_id, expira, agente) values (v_tok, u.id, now() + interval '30 days', left(p_agente, 200));
  return jsonb_build_object('ok', true, 'token', v_tok, 'id', u.id, 'nombre', u.nombre, 'rol', u.rol, 'usuario', u.usuario, 'nivel', v_niv);
end $$;

create or replace function public.nom_logout(p_token text) returns jsonb
language sql security definer set search_path to 'public' as $$
  delete from public.nom_sesiones where token = p_token; select jsonb_build_object('ok', true)
$$;

-- 5. Lectura -------------------------------------------------------------------
create or replace function public.nom_datos(p_token text, p_desde date, p_hasta date)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare s record; v_emp jsonb;
begin
  s := public.nom__sesion(p_token);
  if s.err is not null then return jsonb_build_object('ok', false, 'error', s.err); end if;
  select coalesce(jsonb_agg(case when s.nivel >= 2 then to_jsonb(e) - 'pin_acceso'
           else (to_jsonb(e) - 'pin_acceso' - 'clabe' - 'nss' - 'curp' - 'rfc') end order by e.activo desc, e.nombre), '[]')
    into v_emp from public.nom_empleados e;
  return jsonb_build_object('ok', true,
    'yo', jsonb_build_object('id', (s.u).id, 'nombre', (s.u).nombre, 'rol', (s.u).rol, 'nivel', s.nivel),
    'config', (select coalesce(jsonb_object_agg(clave, valor), '{}') from public.nom_config),
    'empleados', v_emp,
    'mapeo', (select coalesce(jsonb_agg(to_jsonb(m)), '[]') from public.nom_pdf_mapeo m),
    'checadas', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'e', c.empleado_id, 'b', c.bio_id, 'n', c.bio_nombre,
                  'f', c.fecha, 'h', to_char(c.hora, 'HH24:MI'), 'eb', c.estado_bio, 'o', c.origen, 'nota', c.nota, 'x', c.anulada)
                  order by c.fecha, c.hora), '[]')
                 from public.nom_checadas c where c.fecha between p_desde and p_hasta),
    'incidencias', (select coalesce(jsonb_agg(to_jsonb(i) order by i.fecha), '[]') from public.nom_incidencias i
                     where i.fecha <= p_hasta and coalesce(i.fecha_fin, i.fecha) >= p_desde - 400),
    'movimientos', (select coalesce(jsonb_agg(to_jsonb(m) order by m.fecha), '[]') from public.nom_movimientos m
                     where m.fecha between p_desde - 400 and p_hasta + 60),
    'nominas', (select coalesce(jsonb_agg(to_jsonb(n) order by n.fecha_ini desc), '[]') from public.nom_nominas n),
    'recibos', (select coalesce(jsonb_agg(to_jsonb(r)), '[]') from public.nom_recibos r
                 join public.nom_nominas n on n.id = r.nomina_id where n.fecha_fin >= p_desde - 400),
    'egresos', (select coalesce(jsonb_agg(jsonb_build_object('id', f.id, 'estado', f.estado, 'monto', f.monto_total,
                 'pagado', f.monto_pagado, 'anulado', coalesce(f.anulado, false), 'fecha_pago', f.fecha_pago)), '[]')
                from public.fin_facturas f where f.origen = 'nomina'),
    'descuentos', (select coalesce(jsonb_agg(to_jsonb(d) order by d.created_at desc), '[]') from public.nom_descuentos d),
    'descuento_pagos', (select coalesce(jsonb_agg(to_jsonb(p)), '[]') from public.nom_descuento_pagos p),
    'importaciones', (select coalesce(jsonb_agg(to_jsonb(i) order by i.subido_at desc), '[]') from (select * from public.nom_importaciones order by subido_at desc limit 60) i),
    'usuarios', (select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'nombre', x.nombre, 'rol', x.rol, 'usuario', x.usuario,
                  'nivel', public.nom__nivel(x)) order by x.nombre), '[]') from public.fin_usuarios x where x.activo),
    'historial_v1', (select coalesce(jsonb_agg(jsonb_build_object('e', p.empleado_id, 'ini', p.fecha_inicio, 'fin', p.fecha_fin,
                  'neto', p.salario_neto, 'tipo', p.tipo)), '[]') from public.nom_periodos p where p.fecha_fin >= p_desde - 400)
  );
end $$;

create or replace function public.nom_bitacora(p_token text, p_limite int default 300)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare s record;
begin
  s := public.nom__sesion(p_token);
  if s.err is not null then return jsonb_build_object('ok', false, 'error', s.err); end if;
  if s.nivel < 2 then return jsonb_build_object('ok', false, 'error', 'sin_permiso'); end if;
  return jsonb_build_object('ok', true, 'filas', (select coalesce(jsonb_agg(to_jsonb(l) order by l.timestamp desc), '[]') from
    (select id, tabla, registro_id, usuario_nombre, accion, descripcion, antes, despues, timestamp from public.fin_log
      where tabla like 'nom\_%' order by timestamp desc limit least(p_limite, 1000)) l));
end $$;

-- 6. Biométrico ------------------------------------------------------------------
create or replace function public.nom_importar(p_token text, p_pin text, p_datos jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare f record; v_imp uuid; v_n int := 0; v_tot int := 0; r jsonb; v_emp uuid;
begin
  f := public.nom__firmar(p_token, p_pin, 2);
  if f.err is not null then return jsonb_build_object('ok', false, 'error', f.err); end if;
  if exists (select 1 from public.nom_importaciones where sha256 = p_datos->>'sha256') then
    return jsonb_build_object('ok', false, 'error', 'archivo_repetido');
  end if;
  insert into public.nom_importaciones (archivo, url, sha256, desde, hasta, registros, subido_por)
  values (p_datos->>'archivo', p_datos->>'url', p_datos->>'sha256', (p_datos->>'desde')::date, (p_datos->>'hasta')::date,
          jsonb_array_length(p_datos->'filas'), (f.u).id) returning id into v_imp;
  for r in select * from jsonb_array_elements(p_datos->'filas') loop
    v_tot := v_tot + 1;
    v_emp := coalesce(nullif(r->>'e','')::uuid,
                      (select empleado_id from public.nom_pdf_mapeo where bio_id = r->>'b' limit 1));
    insert into public.nom_checadas (empleado_id, bio_id, bio_nombre, fecha, hora, estado_bio, origen, importacion_id, creada_por)
    values (v_emp, r->>'b', r->>'n', (r->>'f')::date, (r->>'h')::time, r->>'eb', 'biometrico', v_imp, (f.u).id)
    on conflict (bio_id, fecha, hora) where origen = 'biometrico' do nothing;
    if found then v_n := v_n + 1; end if;
  end loop;
  update public.nom_importaciones set nuevos = v_n where id = v_imp;
  perform public.nom__log('nom_importaciones', v_imp, 'insert', 'Importó biométrico ' || coalesce(p_datos->>'archivo',''),
          jsonb_build_object('registros', v_tot, 'nuevos', v_n));
  return jsonb_build_object('ok', true, 'nuevos', v_n, 'repetidos', v_tot - v_n);
end $$;

create or replace function public.nom_mapear(p_token text, p_pin text, p_bio_id text, p_bio_nombre text, p_empleado uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare f record; v_n int;
begin
  f := public.nom__firmar(p_token, p_pin, 2);
  if f.err is not null then return jsonb_build_object('ok', false, 'error', f.err); end if;
  delete from public.nom_pdf_mapeo where bio_id = p_bio_id or (bio_id is null and nombre_pdf = p_bio_nombre);
  if p_empleado is not null then
    insert into public.nom_pdf_mapeo (nombre_pdf, empleado_id, bio_id) values (coalesce(nullif(p_bio_nombre,''), p_bio_id), p_empleado, p_bio_id)
    on conflict (nombre_pdf) do update set empleado_id = excluded.empleado_id, bio_id = excluded.bio_id;
  end if;
  update public.nom_checadas c set empleado_id = p_empleado
   where c.bio_id = p_bio_id and c.origen = 'biometrico'
     and (c.empleado_id is null or not public.nom__bloqueado(c.empleado_id, c.fecha));
  get diagnostics v_n = row_count;
  perform public.nom__log('nom_pdf_mapeo', p_empleado, 'update', 'Vinculó ID de checador ' || p_bio_id || ' (' || coalesce(p_bio_nombre,'') || ')',
          jsonb_build_object('bio_id', p_bio_id, 'empleado_id', p_empleado, 'checadas', v_n));
  return jsonb_build_object('ok', true, 'checadas', v_n);
end $$;

-- Agregar una checada que faltó (captura, con motivo)
create or replace function public.nom_checada_manual(p_token text, p_pin text, p_empleado uuid, p_fecha date, p_hora time, p_nota text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare f record; v_id uuid;
begin
  f := public.nom__firmar(p_token, p_pin, 2);
  if f.err is not null then return jsonb_build_object('ok', false, 'error', f.err); end if;
  if coalesce(trim(p_nota), '') = '' then return jsonb_build_object('ok', false, 'error', 'motivo'); end if;
  if public.nom__bloqueado(p_empleado, p_fecha) then return jsonb_build_object('ok', false, 'error', 'pagado'); end if;
  insert into public.nom_checadas (empleado_id, fecha, hora, origen, nota, creada_por)
  values (p_empleado, p_fecha, p_hora, 'manual', trim(p_nota), (f.u).id) returning id into v_id;
  perform public.nom__log('nom_checadas', v_id, 'insert', 'Checada manual: ' || trim(p_nota),
          jsonb_build_object('empleado_id', p_empleado, 'fecha', p_fecha, 'hora', p_hora));
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

-- Anular una checada (información sensible: doble PIN)
create or replace function public.nom_checada_anular(p_token text, p_pin text, p_pin2 text, p_id uuid, p_motivo text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare f record; g record; c public.nom_checadas;
begin
  f := public.nom__firmar(p_token, p_pin, 2);
  if f.err is not null then return jsonb_build_object('ok', false, 'error', f.err); end if;
  if coalesce(trim(p_motivo), '') = '' then return jsonb_build_object('ok', false, 'error', 'motivo'); end if;
  select * into c from public.nom_checadas where id = p_id;
  if c.id is null or c.anulada then return jsonb_build_object('ok', false, 'error', 'estado'); end if;
  if public.nom__bloqueado(c.empleado_id, c.fecha) then return jsonb_build_object('ok', false, 'error', 'pagado'); end if;
  g := public.nom__segunda(f.u, p_pin2);
  if g.err is not null then return jsonb_build_object('ok', false, 'error', g.err); end if;
  update public.nom_checadas set anulada = true, anulada_por = (f.u).id, anulada_at = now(),
    anulada_motivo = trim(p_motivo) || ' · 2a firma: ' || (g.d).nombre where id = p_id;
  return jsonb_build_object('ok', true);
end $$;

-- 7. Incidencias y movimientos ---------------------------------------------------
create or replace function public.nom_incidencia_guardar(p_token text, p_pin text, p_datos jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare f record; v_id uuid; v_emp uuid; v_ids jsonb := '[]'; d date;
begin
  f := public.nom__firmar(p_token, p_pin, 2);
  if f.err is not null then return jsonb_build_object('ok', false, 'error', f.err); end if;
  if coalesce(trim(p_datos->>'nota'), '') = '' then return jsonb_build_object('ok', false, 'error', 'motivo'); end if;
  d := (p_datos->>'fecha')::date;
  for v_emp in select (jsonb_array_elements_text(coalesce(p_datos->'empleados', jsonb_build_array(p_datos->>'empleado_id'))))::uuid loop
    if public.nom__bloqueado(v_emp, d) then return jsonb_build_object('ok', false, 'error', 'pagado'); end if;
    insert into public.nom_incidencias (empleado_id, fecha, fecha_fin, tipo, con_goce, horas, nota, evidencia_url, creada_por)
    values (v_emp, d, nullif(p_datos->>'fecha_fin','')::date, p_datos->>'tipo', coalesce((p_datos->>'con_goce')::boolean, true),
            nullif(p_datos->>'horas','')::numeric, trim(p_datos->>'nota'), nullif(p_datos->>'evidencia_url',''), (f.u).id)
    returning id into v_id;
    v_ids := v_ids || to_jsonb(v_id);
  end loop;
  return jsonb_build_object('ok', true, 'ids', v_ids);
end $$;

create or replace function public.nom_incidencia_anular(p_token text, p_pin text, p_pin2 text, p_id uuid, p_motivo text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare f record; g record; i public.nom_incidencias;
begin
  f := public.nom__firmar(p_token, p_pin, 2);
  if f.err is not null then return jsonb_build_object('ok', false, 'error', f.err); end if;
  if coalesce(trim(p_motivo), '') = '' then return jsonb_build_object('ok', false, 'error', 'motivo'); end if;
  select * into i from public.nom_incidencias where id = p_id;
  if i.id is null or i.anulada then return jsonb_build_object('ok', false, 'error', 'estado'); end if;
  if i.nomina_id is not null or public.nom__bloqueado(i.empleado_id, i.fecha) then return jsonb_build_object('ok', false, 'error', 'pagado'); end if;
  g := public.nom__segunda(f.u, p_pin2);
  if g.err is not null then return jsonb_build_object('ok', false, 'error', g.err); end if;
  update public.nom_incidencias set anulada = true, anulada_por = (f.u).id, anulada_at = now(),
    anulada_motivo = trim(p_motivo) || ' · 2a firma: ' || (g.d).nombre where id = p_id;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.nom_movimiento_guardar(p_token text, p_pin text, p_datos jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare f record; v_id uuid;
begin
  f := public.nom__firmar(p_token, p_pin, 2);
  if f.err is not null then return jsonb_build_object('ok', false, 'error', f.err); end if;
  if coalesce(trim(p_datos->>'concepto'), '') = '' then return jsonb_build_object('ok', false, 'error', 'descripcion'); end if;
  if coalesce(nullif(p_datos->>'monto','')::numeric, 0) <= 0 then return jsonb_build_object('ok', false, 'error', 'monto'); end if;
  if public.nom__bloqueado((p_datos->>'empleado_id')::uuid, (p_datos->>'fecha')::date) then return jsonb_build_object('ok', false, 'error', 'pagado'); end if;
  insert into public.nom_movimientos (empleado_id, fecha, tipo, concepto, monto, gravable, nota, creada_por)
  values ((p_datos->>'empleado_id')::uuid, (p_datos->>'fecha')::date, p_datos->>'tipo', trim(p_datos->>'concepto'),
          (p_datos->>'monto')::numeric, coalesce((p_datos->>'gravable')::boolean, true), nullif(p_datos->>'nota',''), (f.u).id)
  returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

create or replace function public.nom_movimiento_anular(p_token text, p_pin text, p_pin2 text, p_id uuid, p_motivo text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare f record; g record; m public.nom_movimientos;
begin
  f := public.nom__firmar(p_token, p_pin, 2);
  if f.err is not null then return jsonb_build_object('ok', false, 'error', f.err); end if;
  if coalesce(trim(p_motivo), '') = '' then return jsonb_build_object('ok', false, 'error', 'motivo'); end if;
  select * into m from public.nom_movimientos where id = p_id;
  if m.id is null or m.anulada then return jsonb_build_object('ok', false, 'error', 'estado'); end if;
  if m.nomina_id is not null then return jsonb_build_object('ok', false, 'error', 'pagado'); end if;
  g := public.nom__segunda(f.u, p_pin2);
  if g.err is not null then return jsonb_build_object('ok', false, 'error', g.err); end if;
  update public.nom_movimientos set anulada = true, anulada_por = (f.u).id, anulada_at = now(),
    anulada_motivo = trim(p_motivo) || ' · 2a firma: ' || (g.d).nombre where id = p_id;
  return jsonb_build_object('ok', true);
end $$;

-- 8. Empleados -------------------------------------------------------------------
-- Campos sensibles: cambiarlos en un empleado existente requiere doble PIN.
create or replace function public.nom_empleado_guardar(p_token text, p_pin text, p_pin2 text, p_datos jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare f record; g record; e public.nom_empleados; v_id uuid := nullif(p_datos->>'id','')::uuid;
  v_sens text[] := array['salario_diario','salario_base','salario_fiscal','bono_puntualidad','bono_asistencia','bono_no_fiscal',
                         'esquema','banco','clabe','rfc','nss','curp','fecha_ingreso','retener_isr','retener_imss','activo','fecha_baja'];
  k text; v_cambio text[] := '{}';
begin
  f := public.nom__firmar(p_token, p_pin, 2);
  if f.err is not null then return jsonb_build_object('ok', false, 'error', f.err); end if;
  if coalesce(trim(p_datos->>'nombre'), '') = '' then return jsonb_build_object('ok', false, 'error', 'nombre'); end if;
  if v_id is not null then
    select * into e from public.nom_empleados where id = v_id;
    if e.id is null then return jsonb_build_object('ok', false, 'error', 'usuario'); end if;
    foreach k in array v_sens loop
      if p_datos ? k and (to_jsonb(e)->>k) is distinct from nullif(p_datos->>k, '') then
        if not (k in ('salario_diario','salario_base','salario_fiscal','bono_puntualidad','bono_asistencia','bono_no_fiscal')
                and coalesce((to_jsonb(e)->>k)::numeric, 0) = coalesce(nullif(p_datos->>k,'')::numeric, 0)) then
          v_cambio := v_cambio || k;
        end if;
      end if;
    end loop;
    if array_length(v_cambio, 1) > 0 then
      g := public.nom__segunda(f.u, p_pin2);
      if g.err is not null then return jsonb_build_object('ok', false, 'error', g.err, 'campos', to_jsonb(v_cambio)); end if;
    end if;
  end if;
  if v_id is null then
    insert into public.nom_empleados (nombre, activo) values (trim(p_datos->>'nombre'), true) returning id into v_id;
  end if;
  update public.nom_empleados set
    nombre = trim(p_datos->>'nombre'),
    puesto = coalesce(p_datos->>'puesto', puesto),
    esquema = coalesce(nullif(p_datos->>'esquema',''), esquema, 'fijo'),
    periodicidad = 'quincenal',
    salario_diario = coalesce(nullif(p_datos->>'salario_diario','')::numeric, salario_diario),
    salario_base = coalesce(nullif(p_datos->>'salario_diario','')::numeric * 15, salario_base),
    salario_fiscal = case when p_datos ? 'salario_fiscal' then nullif(p_datos->>'salario_fiscal','')::numeric else salario_fiscal end,
    bono_puntualidad = case when p_datos ? 'bono_puntualidad' then coalesce(nullif(p_datos->>'bono_puntualidad','')::numeric, 0) else bono_puntualidad end,
    bono_asistencia = case when p_datos ? 'bono_asistencia' then coalesce(nullif(p_datos->>'bono_asistencia','')::numeric, 0) else bono_asistencia end,
    bono_no_fiscal = case when p_datos ? 'bono_no_fiscal' then coalesce(nullif(p_datos->>'bono_no_fiscal','')::numeric, 0) else bono_no_fiscal end,
    fecha_ingreso = case when p_datos ? 'fecha_ingreso' then nullif(p_datos->>'fecha_ingreso','')::date else fecha_ingreso end,
    rfc = case when p_datos ? 'rfc' then nullif(upper(p_datos->>'rfc'),'') else rfc end,
    nss = case when p_datos ? 'nss' then nullif(p_datos->>'nss','') else nss end,
    curp = case when p_datos ? 'curp' then nullif(upper(p_datos->>'curp'),'') else curp end,
    banco = case when p_datos ? 'banco' then nullif(p_datos->>'banco','') else banco end,
    clabe = case when p_datos ? 'clabe' then nullif(p_datos->>'clabe','') else clabe end,
    sede = coalesce(nullif(p_datos->>'sede',''), sede, 'Tacámbaro'),
    horario = coalesce(p_datos->'horario', horario),
    controla_asistencia = coalesce((p_datos->>'controla_asistencia')::boolean, controla_asistencia, true),
    retener_isr = coalesce((p_datos->>'retener_isr')::boolean, retener_isr, false),
    retener_imss = coalesce((p_datos->>'retener_imss')::boolean, retener_imss, false),
    telefono = case when p_datos ? 'telefono' then nullif(p_datos->>'telefono','') else telefono end,
    email = case when p_datos ? 'email' then nullif(p_datos->>'email','') else email end,
    forma_pago = coalesce(nullif(p_datos->>'forma_pago',''), forma_pago, 'transferencia'),
    notas = case when p_datos ? 'notas' then nullif(p_datos->>'notas','') else notas end,
    activo = coalesce((p_datos->>'activo')::boolean, activo, true),
    fecha_baja = case when p_datos ? 'fecha_baja' then nullif(p_datos->>'fecha_baja','')::date else fecha_baja end,
    motivo_baja = case when p_datos ? 'motivo_baja' then nullif(p_datos->>'motivo_baja','') else motivo_baja end,
    updated_at = now()
  where id = v_id;
  return jsonb_build_object('ok', true, 'id', v_id, 'sensibles', to_jsonb(v_cambio));
end $$;

-- 9. Préstamos y descuentos en parcialidades ------------------------------------
create or replace function public.nom_descuento_guardar(p_token text, p_pin text, p_datos jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare f record; v_id uuid; v_tot numeric := nullif(p_datos->>'monto_total','')::numeric; v_n int := coalesce(nullif(p_datos->>'cuotas_total','')::int, 1);
begin
  f := public.nom__firmar(p_token, p_pin, 2);
  if f.err is not null then return jsonb_build_object('ok', false, 'error', f.err); end if;
  if v_tot is null or v_tot <= 0 then return jsonb_build_object('ok', false, 'error', 'monto'); end if;
  if coalesce(trim(p_datos->>'descripcion'),'') = '' then return jsonb_build_object('ok', false, 'error', 'descripcion'); end if;
  insert into public.nom_descuentos (empleado_id, tipo, descripcion, monto_total, monto_cuota, cuotas_total, cuotas_pagadas, activo, created_by, fecha_inicio)
  values ((p_datos->>'empleado_id')::uuid, coalesce(nullif(p_datos->>'tipo',''), 'otro'), trim(p_datos->>'descripcion'), v_tot,
          round(v_tot / v_n, 2), v_n, 0, true, (f.u).nombre, coalesce(nullif(p_datos->>'fecha_inicio','')::date, current_date))
  returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

create or replace function public.nom_descuento_anular(p_token text, p_pin text, p_pin2 text, p_id uuid, p_motivo text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare f record; g record;
begin
  f := public.nom__firmar(p_token, p_pin, 2);
  if f.err is not null then return jsonb_build_object('ok', false, 'error', f.err); end if;
  if coalesce(trim(p_motivo), '') = '' then return jsonb_build_object('ok', false, 'error', 'motivo'); end if;
  g := public.nom__segunda(f.u, p_pin2);
  if g.err is not null then return jsonb_build_object('ok', false, 'error', g.err); end if;
  update public.nom_descuentos set activo = false, anulado = true,
    anulado_motivo = trim(p_motivo) || ' · 2a firma: ' || (g.d).nombre where id = p_id;
  return jsonb_build_object('ok', true);
end $$;

-- 10. Nóminas --------------------------------------------------------------------
create or replace function public.nom_nomina_crear(p_token text, p_pin text, p_datos jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare f record; v_id uuid; v_folio text; v_ini date := (p_datos->>'fecha_ini')::date; v_fin date := (p_datos->>'fecha_fin')::date;
  v_tipo text := coalesce(nullif(p_datos->>'tipo',''), 'ordinaria'); v_sede text := coalesce(nullif(p_datos->>'sede',''), 'Tacámbaro');
begin
  f := public.nom__firmar(p_token, p_pin, 2);
  if f.err is not null then return jsonb_build_object('ok', false, 'error', f.err); end if;
  if v_ini is null or v_fin is null or v_fin < v_ini then return jsonb_build_object('ok', false, 'error', 'fechas'); end if;
  if v_tipo = 'ordinaria' and exists (select 1 from public.nom_nominas where tipo = 'ordinaria' and sede = v_sede
        and estado <> 'cancelada' and daterange(fecha_ini, fecha_fin, '[]') && daterange(v_ini, v_fin, '[]')) then
    return jsonb_build_object('ok', false, 'error', 'traslape');
  end if;
  insert into public.nom_nominas (tipo, sede, fecha_ini, fecha_fin, fecha_pago, notas, creada_por)
  values (v_tipo, v_sede, v_ini, v_fin, coalesce(nullif(p_datos->>'fecha_pago','')::date, v_fin), nullif(p_datos->>'notas',''), (f.u).id)
  returning id, folio into v_id, v_folio;
  return jsonb_build_object('ok', true, 'id', v_id, 'folio', v_folio);
end $$;

create or replace function public.nom_nomina_guardar(p_token text, p_pin text, p_nomina uuid, p_recibos jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare f record; n public.nom_nominas; r jsonb;
begin
  f := public.nom__firmar(p_token, p_pin, 2);
  if f.err is not null then return jsonb_build_object('ok', false, 'error', f.err); end if;
  select * into n from public.nom_nominas where id = p_nomina for update;
  if n.id is null or n.estado not in ('borrador','calculada','observada','revisada') then return jsonb_build_object('ok', false, 'error', 'estado'); end if;
  delete from public.nom_recibos where nomina_id = p_nomina;
  for r in select * from jsonb_array_elements(p_recibos) loop
    insert into public.nom_recibos (nomina_id, empleado_id, detalle, percepciones, deducciones, neto)
    values (p_nomina, (r->>'empleado_id')::uuid, r->'detalle', (r->>'percepciones')::numeric, (r->>'deducciones')::numeric, (r->>'neto')::numeric);
  end loop;
  update public.nom_nominas set estado = 'calculada', calculada_por = (f.u).id, calculada_at = now(),
    revisada_por = null, revisada_at = null,
    percepciones = (select coalesce(sum(percepciones),0) from public.nom_recibos where nomina_id = p_nomina),
    deducciones = (select coalesce(sum(deducciones),0) from public.nom_recibos where nomina_id = p_nomina),
    neto = (select coalesce(sum(neto),0) from public.nom_recibos where nomina_id = p_nomina),
    empleados = (select count(*) from public.nom_recibos where nomina_id = p_nomina)
  where id = p_nomina;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.nom_nomina_revisar(p_token text, p_pin text, p_nomina uuid, p_decision text, p_nota text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare f record; n public.nom_nominas;
begin
  f := public.nom__firmar(p_token, p_pin, 2);
  if f.err is not null then return jsonb_build_object('ok', false, 'error', f.err); end if;
  select * into n from public.nom_nominas where id = p_nomina for update;
  if n.id is null or n.estado not in ('calculada','observada','revisada') then return jsonb_build_object('ok', false, 'error', 'estado'); end if;
  if p_decision = 'observada' and coalesce(trim(p_nota),'') = '' then return jsonb_build_object('ok', false, 'error', 'nota'); end if;
  update public.nom_nominas set estado = case when p_decision = 'observada' then 'observada' else 'revisada' end,
    revisada_por = (f.u).id, revisada_at = now(), revision_nota = nullif(trim(p_nota),'') where id = p_nomina;
  return jsonb_build_object('ok', true);
end $$;

-- Autorizar (Director): genera el egreso en COE Finanzas y aplica las parcialidades
create or replace function public.nom_nomina_autorizar(p_token text, p_pin text, p_nomina uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare f record; n public.nom_nominas; r record; d jsonb; v_ent uuid; v_rs uuid; v_fid uuid; v_modo text;
  v_desc text; v_per text; v_det text := ''; v_n int := 0;
begin
  f := public.nom__firmar(p_token, p_pin, 3);
  if f.err is not null then return jsonb_build_object('ok', false, 'error', f.err); end if;
  select * into n from public.nom_nominas where id = p_nomina for update;
  if n.id is null or n.estado <> 'revisada' then return jsonb_build_object('ok', false, 'error', 'no_revisada'); end if;
  if not exists (select 1 from public.nom_recibos where nomina_id = p_nomina) then return jsonb_build_object('ok', false, 'error', 'sin_recibos'); end if;

  select id into v_ent from public.fin_entidades where nombre = 'NÓMINA COE' limit 1;
  if v_ent is null then
    insert into public.fin_entidades (nombre, tipo, categoria, activo, no_factura, dias_credito, notas)
    values ('NÓMINA COE', 'proveedor', 'Nómina', true, true, 0, 'Generado por COE Nómina') returning id into v_ent;
  end if;
  select id into v_rs from public.fin_razones_sociales where activo order by created_at limit 1;
  v_modo := coalesce((select valor->>'egreso_modo' from public.nom_config where clave = 'reglas'), 'por_empleado');
  v_per := case n.tipo when 'ordinaria' then 'Nómina ' when 'aguinaldo' then 'Aguinaldo ' when 'finiquito' then 'Finiquito ' else 'Pago extraordinario ' end
           || to_char(n.fecha_ini, 'DD/MM') || '–' || to_char(n.fecha_fin, 'DD/MM/YYYY') || ' · ' || n.folio;

  for r in select x.*, e.nombre, e.clabe, e.banco, e.forma_pago from public.nom_recibos x join public.nom_empleados e on e.id = x.empleado_id
           where x.nomina_id = p_nomina order by e.nombre loop
    v_det := v_det || r.nombre || ': $' || to_char(r.neto, 'FM999,999,990.00') || E'\n';
    if v_modo = 'por_empleado' and r.neto > 0 then
      insert into public.fin_facturas (tipo, tipo_movimiento, entidad_id, descripcion, categoria, monto_total, monto_pagado,
        fecha_vencimiento, estado, notas, created_by, updated_by, razon_social_id, sede, origen, origen_id, documento_tipo,
        factura_pendiente, clabe_proveedor, firma1_por, firma1_at, aprobado_por, aprobado_at)
      values ('egreso', 'normal', v_ent, v_per || ' · ' || r.nombre, 'Nómina', r.neto, 0, n.fecha_pago, 'pendiente',
        'Pago por ' || coalesce(r.forma_pago, 'transferencia') || coalesce(' · ' || r.banco, ''), (f.u).id, (f.u).id, v_rs, n.sede,
        'nomina', p_nomina::text, 'sin_factura', false, r.clabe, (f.u).id, now(), (f.u).nombre, now())
      returning id into v_fid;
      update public.nom_recibos set egreso_id = v_fid where id = r.id;
    end if;
    -- parcialidades de préstamos/descuentos incluidas en el recibo
    for d in select * from jsonb_array_elements(coalesce(r.detalle->'deducciones', '[]')) loop
      if nullif(d->>'descuento_id','') is not null then
        insert into public.nom_descuento_pagos (descuento_id, empleado_id, monto, fecha_pago, nomina_id)
        values ((d->>'descuento_id')::uuid, r.empleado_id, (d->>'monto')::numeric, n.fecha_pago, p_nomina);
        update public.nom_descuentos set cuotas_pagadas = cuotas_pagadas + 1,
          activo = (cuotas_pagadas + 1) < cuotas_total where id = (d->>'descuento_id')::uuid;
      end if;
    end loop;
    v_n := v_n + 1;
  end loop;

  if v_modo <> 'por_empleado' then
    insert into public.fin_facturas (tipo, tipo_movimiento, entidad_id, descripcion, categoria, monto_total, monto_pagado,
      fecha_vencimiento, estado, notas, created_by, updated_by, razon_social_id, sede, origen, origen_id, documento_tipo,
      factura_pendiente, firma1_por, firma1_at, aprobado_por, aprobado_at)
    values ('egreso', 'normal', v_ent, v_per || ' · ' || v_n || ' empleados', 'Nómina', n.neto, 0, n.fecha_pago, 'pendiente',
      v_det, (f.u).id, (f.u).id, v_rs, n.sede, 'nomina', p_nomina::text, 'sin_factura', false, (f.u).id, now(), (f.u).nombre, now())
    returning id into v_fid;
    update public.nom_recibos set egreso_id = v_fid where nomina_id = p_nomina;
  end if;

  if n.tipo = 'ordinaria' then
    update public.nom_incidencias i set nomina_id = p_nomina
     where i.nomina_id is null and not i.anulada and i.fecha between n.fecha_ini and n.fecha_fin
       and i.empleado_id in (select empleado_id from public.nom_recibos where nomina_id = p_nomina);
  end if;
  update public.nom_movimientos m set nomina_id = p_nomina
   where m.nomina_id is null and not m.anulada and m.id in (
     select (x->>'movimiento_id')::uuid from public.nom_recibos rr,
       jsonb_array_elements(coalesce(rr.detalle->'percepciones','[]') || coalesce(rr.detalle->'deducciones','[]')) x
      where rr.nomina_id = p_nomina and nullif(x->>'movimiento_id','') is not null);

  update public.nom_nominas set estado = 'autorizada', autorizada_por = (f.u).id, autorizada_at = now() where id = p_nomina;
  return jsonb_build_object('ok', true, 'recibos', v_n);
end $$;

-- Reabrir una nómina autorizada (doble PIN). Solo si no se ha pagado nada en Finanzas.
create or replace function public.nom_nomina_reabrir(p_token text, p_pin text, p_pin2 text, p_nomina uuid, p_motivo text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare f record; g record; n public.nom_nominas; p record;
begin
  f := public.nom__firmar(p_token, p_pin, 2);
  if f.err is not null then return jsonb_build_object('ok', false, 'error', f.err); end if;
  if coalesce(trim(p_motivo), '') = '' then return jsonb_build_object('ok', false, 'error', 'motivo'); end if;
  select * into n from public.nom_nominas where id = p_nomina for update;
  if n.id is null or n.estado <> 'autorizada' then return jsonb_build_object('ok', false, 'error', 'estado'); end if;
  if exists (select 1 from public.fin_facturas where origen = 'nomina' and origen_id = p_nomina::text
              and not coalesce(anulado,false) and coalesce(monto_pagado,0) > 0) then
    return jsonb_build_object('ok', false, 'error', 'con_pagos');
  end if;
  g := public.nom__segunda(f.u, p_pin2);
  if g.err is not null then return jsonb_build_object('ok', false, 'error', g.err); end if;
  update public.fin_facturas set anulado = true, anulado_motivo = 'Nómina reabierta: ' || trim(p_motivo), anulado_por = (f.u).id,
    anulado_at = now(), estado = 'cancelado' where origen = 'nomina' and origen_id = p_nomina::text and not coalesce(anulado,false);
  for p in select * from public.nom_descuento_pagos where nomina_id = p_nomina loop
    update public.nom_descuentos set cuotas_pagadas = greatest(cuotas_pagadas - 1, 0), activo = not coalesce(anulado,false) where id = p.descuento_id;
  end loop;
  delete from public.nom_descuento_pagos where nomina_id = p_nomina;
  update public.nom_incidencias set nomina_id = null where nomina_id = p_nomina;
  update public.nom_movimientos set nomina_id = null where nomina_id = p_nomina;
  update public.nom_recibos set egreso_id = null where nomina_id = p_nomina;
  update public.nom_nominas set estado = 'observada', autorizada_por = null, autorizada_at = null,
    revision_nota = 'Reabierta: ' || trim(p_motivo) || ' · 2a firma: ' || (g.d).nombre where id = p_nomina;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.nom_nomina_cancelar(p_token text, p_pin text, p_pin2 text, p_nomina uuid, p_motivo text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare f record; g record; n public.nom_nominas;
begin
  f := public.nom__firmar(p_token, p_pin, 2);
  if f.err is not null then return jsonb_build_object('ok', false, 'error', f.err); end if;
  if coalesce(trim(p_motivo), '') = '' then return jsonb_build_object('ok', false, 'error', 'motivo'); end if;
  select * into n from public.nom_nominas where id = p_nomina for update;
  if n.id is null or n.estado in ('autorizada','cancelada') then return jsonb_build_object('ok', false, 'error', 'estado'); end if;
  g := public.nom__segunda(f.u, p_pin2);
  if g.err is not null then return jsonb_build_object('ok', false, 'error', g.err); end if;
  update public.nom_nominas set estado = 'cancelada', cancelada_por = (f.u).id, cancelada_at = now(),
    cancelada_motivo = trim(p_motivo) || ' · 2a firma: ' || (g.d).nombre where id = p_nomina;
  return jsonb_build_object('ok', true);
end $$;

-- 11. Configuración y permisos -----------------------------------------------------
create or replace function public.nom_config_guardar(p_token text, p_pin text, p_pin2 text, p_clave text, p_valor jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare f record; g record;
begin
  f := public.nom__firmar(p_token, p_pin, 2);
  if f.err is not null then return jsonb_build_object('ok', false, 'error', f.err); end if;
  if p_clave not in ('reglas','fiscal') then return jsonb_build_object('ok', false, 'error', 'tabla'); end if;
  g := public.nom__segunda(f.u, p_pin2);
  if g.err is not null then return jsonb_build_object('ok', false, 'error', g.err); end if;
  insert into public.nom_config (clave, valor, updated_at, updated_by) values (p_clave, p_valor, now(), (f.u).nombre || ' + ' || (g.d).nombre)
  on conflict (clave) do update set valor = excluded.valor, updated_at = now(), updated_by = excluded.updated_by;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.nom_permiso_guardar(p_token text, p_pin text, p_usuario uuid, p_nivel int)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare f record;
begin
  f := public.nom__firmar(p_token, p_pin, 3);
  if f.err is not null then return jsonb_build_object('ok', false, 'error', f.err); end if;
  if (f.u).rol <> 'admin' then return jsonb_build_object('ok', false, 'error', 'solo_director'); end if;
  if p_usuario = (f.u).id then return jsonb_build_object('ok', false, 'error', 'propio'); end if;
  if p_nivel not between 0 and 3 then return jsonb_build_object('ok', false, 'error', 'nivel'); end if;
  insert into public.nom_permisos (usuario_id, nivel) values (p_usuario, p_nivel)
  on conflict (usuario_id) do update set nivel = excluded.nivel, updated_at = now();
  delete from public.nom_sesiones where usuario_id = p_usuario and p_nivel = 0;
  return jsonb_build_object('ok', true);
end $$;

-- Las funciones auxiliares (doble guion bajo) no se exponen a la llave pública
revoke execute on function public.nom__nivel(public.fin_usuarios) from public, anon, authenticated;
revoke execute on function public.nom__sesion(text) from public, anon, authenticated;
revoke execute on function public.nom__firmar(text, text, int) from public, anon, authenticated;
revoke execute on function public.nom__segunda(public.fin_usuarios, text) from public, anon, authenticated;
revoke execute on function public.nom__log(text, uuid, text, text, jsonb) from public, anon, authenticated;
revoke execute on function public.nom__bloqueado(uuid, date) from public, anon, authenticated;
-- ═══════════════════════════════════════════════════════════════════════
-- COE Nómina 2.0 · Ajustes 1 (aditivo; correr DESPUÉS de nom2_base.sql)
-- Coberturas, permutas, días a cuenta de vacaciones, permisos por horas,
-- días/horas extra pagados, clases de bonos y comisiones (las comisiones
-- NO integran salario: no entran a finiquito, aguinaldo ni prestaciones),
-- pausar parcialidades de préstamos.
-- ═══════════════════════════════════════════════════════════════════════

alter table public.nom_incidencias add column if not exists monto numeric;
alter table public.nom_incidencias add column if not exists fecha_cambio date;
alter table public.nom_incidencias add column if not exists otro_empleado_id uuid references public.nom_empleados(id);
alter table public.nom_incidencias add column if not exists vinculada_id uuid;
alter table public.nom_incidencias drop constraint if exists nom_incidencias_tipo_check;
alter table public.nom_incidencias add constraint nom_incidencias_tipo_check check (tipo in (
  'justificada','permiso_con_goce','permiso_sin_goce','permiso_horas','incapacidad','vacaciones','vac_a_cuenta',
  'retardo_justificado','falla_checador','horas_extra','dia_extra','cobertura','permuta',
  'festivo_laborado','descanso_laborado','suspension','dia_libre'));

alter table public.nom_movimientos add column if not exists clase text default 'otro';
alter table public.nom_movimientos add column if not exists integra_salario boolean default true;
alter table public.nom_movimientos drop constraint if exists nom_movimientos_clase_check;
alter table public.nom_movimientos add constraint nom_movimientos_clase_check check (clase in
  ('comision','bono','cobertura','extra','reembolso','anticipo','faltante','descuento','otro'));
update public.nom_movimientos set clase = 'comision', integra_salario = false where clase = 'otro' and concepto ilike '%comisi%';

alter table public.nom_descuentos add column if not exists pausado boolean default false;

insert into public.nom_config (clave, valor) values ('reglas', '{}'::jsonb) on conflict (clave) do nothing;
update public.nom_config set valor = jsonb_build_object(
    'cobertura_factor', 1, 'horas_extra_modo', 'ley', 'dia_extra_factor', 1, 'descontar_prestamos_finiquito', true) || valor
 where clave = 'reglas';

-- Incidencias (con coberturas y permutas). La permuta entre dos empleados crea la contraparte.
create or replace function public.nom_incidencia_guardar(p_token text, p_pin text, p_datos jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare f record; v_id uuid; v_id2 uuid; v_emp uuid; v_ids jsonb := '[]'; d date; v_tipo text := p_datos->>'tipo';
  v_cambio date := nullif(p_datos->>'fecha_cambio','')::date; v_otro uuid := nullif(p_datos->>'otro_empleado_id','')::uuid;
  v_horas numeric := nullif(p_datos->>'horas','')::numeric; v_monto numeric := nullif(p_datos->>'monto','')::numeric;
begin
  f := public.nom__firmar(p_token, p_pin, 2);
  if f.err is not null then return jsonb_build_object('ok', false, 'error', f.err); end if;
  if coalesce(trim(p_datos->>'nota'), '') = '' then return jsonb_build_object('ok', false, 'error', 'motivo'); end if;
  if v_tipo in ('horas_extra','permiso_horas') and coalesce(v_horas, 0) <= 0 then return jsonb_build_object('ok', false, 'error', 'horas'); end if;
  if v_tipo = 'cobertura' and coalesce(v_horas, 0) <= 0 and coalesce(v_monto, 0) <= 0 then return jsonb_build_object('ok', false, 'error', 'horas'); end if;
  if v_tipo = 'permuta' and v_cambio is null then return jsonb_build_object('ok', false, 'error', 'fecha_cambio'); end if;
  if v_monto is not null and v_monto < 0 then return jsonb_build_object('ok', false, 'error', 'monto'); end if;
  d := (p_datos->>'fecha')::date;
  for v_emp in select (jsonb_array_elements_text(coalesce(p_datos->'empleados', jsonb_build_array(p_datos->>'empleado_id'))))::uuid loop
    if public.nom__bloqueado(v_emp, d) or (v_cambio is not null and public.nom__bloqueado(v_emp, v_cambio)) then
      return jsonb_build_object('ok', false, 'error', 'pagado');
    end if;
    insert into public.nom_incidencias (empleado_id, fecha, fecha_fin, tipo, con_goce, horas, monto, fecha_cambio, otro_empleado_id, nota, evidencia_url, creada_por)
    values (v_emp, d, nullif(p_datos->>'fecha_fin','')::date, v_tipo, coalesce((p_datos->>'con_goce')::boolean, true),
            v_horas, v_monto, v_cambio, v_otro, trim(p_datos->>'nota'), nullif(p_datos->>'evidencia_url',''), (f.u).id)
    returning id into v_id;
    v_ids := v_ids || to_jsonb(v_id);
    if v_tipo = 'permuta' and v_otro is not null and v_otro <> v_emp then
      if public.nom__bloqueado(v_otro, d) or public.nom__bloqueado(v_otro, v_cambio) then return jsonb_build_object('ok', false, 'error', 'pagado'); end if;
      insert into public.nom_incidencias (empleado_id, fecha, tipo, con_goce, fecha_cambio, otro_empleado_id, nota, evidencia_url, creada_por, vinculada_id)
      values (v_otro, v_cambio, 'permuta', true, d, v_emp, trim(p_datos->>'nota'), nullif(p_datos->>'evidencia_url',''), (f.u).id, v_id)
      returning id into v_id2;
      update public.nom_incidencias set vinculada_id = v_id2 where id = v_id;
    end if;
  end loop;
  return jsonb_build_object('ok', true, 'ids', v_ids);
end $$;

-- Al anular una permuta se anula también su contraparte
create or replace function public.nom_incidencia_anular(p_token text, p_pin text, p_pin2 text, p_id uuid, p_motivo text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare f record; g record; i public.nom_incidencias;
begin
  f := public.nom__firmar(p_token, p_pin, 2);
  if f.err is not null then return jsonb_build_object('ok', false, 'error', f.err); end if;
  if coalesce(trim(p_motivo), '') = '' then return jsonb_build_object('ok', false, 'error', 'motivo'); end if;
  select * into i from public.nom_incidencias where id = p_id;
  if i.id is null or i.anulada then return jsonb_build_object('ok', false, 'error', 'estado'); end if;
  if i.nomina_id is not null or public.nom__bloqueado(i.empleado_id, i.fecha) then return jsonb_build_object('ok', false, 'error', 'pagado'); end if;
  g := public.nom__segunda(f.u, p_pin2);
  if g.err is not null then return jsonb_build_object('ok', false, 'error', g.err); end if;
  update public.nom_incidencias set anulada = true, anulada_por = (f.u).id, anulada_at = now(),
    anulada_motivo = trim(p_motivo) || ' · 2a firma: ' || (g.d).nombre
   where (id = p_id or id = i.vinculada_id or vinculada_id = p_id) and not anulada and nomina_id is null;
  return jsonb_build_object('ok', true);
end $$;

-- Bonos, comisiones y descuentos (las comisiones nunca integran salario)
create or replace function public.nom_movimiento_guardar(p_token text, p_pin text, p_datos jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare f record; v_id uuid; v_clase text := coalesce(nullif(p_datos->>'clase',''), 'otro');
begin
  f := public.nom__firmar(p_token, p_pin, 2);
  if f.err is not null then return jsonb_build_object('ok', false, 'error', f.err); end if;
  if coalesce(trim(p_datos->>'concepto'), '') = '' then return jsonb_build_object('ok', false, 'error', 'descripcion'); end if;
  if coalesce(nullif(p_datos->>'monto','')::numeric, 0) <= 0 then return jsonb_build_object('ok', false, 'error', 'monto'); end if;
  if public.nom__bloqueado((p_datos->>'empleado_id')::uuid, (p_datos->>'fecha')::date) then return jsonb_build_object('ok', false, 'error', 'pagado'); end if;
  insert into public.nom_movimientos (empleado_id, fecha, tipo, clase, concepto, monto, gravable, integra_salario, nota, creada_por)
  values ((p_datos->>'empleado_id')::uuid, (p_datos->>'fecha')::date, p_datos->>'tipo', v_clase, trim(p_datos->>'concepto'),
          (p_datos->>'monto')::numeric, coalesce((p_datos->>'gravable')::boolean, true),
          case when v_clase = 'comision' then false else coalesce((p_datos->>'integra_salario')::boolean, v_clase not in ('reembolso')) end,
          nullif(p_datos->>'nota',''), (f.u).id)
  returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

-- Pausar / reanudar parcialidades de un préstamo (una quincena sin descuento, etc.)
create or replace function public.nom_descuento_pausar(p_token text, p_pin text, p_id uuid, p_pausar boolean, p_motivo text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare f record;
begin
  f := public.nom__firmar(p_token, p_pin, 2);
  if f.err is not null then return jsonb_build_object('ok', false, 'error', f.err); end if;
  if coalesce(trim(p_motivo), '') = '' then return jsonb_build_object('ok', false, 'error', 'motivo'); end if;
  update public.nom_descuentos set pausado = p_pausar where id = p_id and activo and not coalesce(anulado, false);
  if not found then return jsonb_build_object('ok', false, 'error', 'estado'); end if;
  perform public.nom__log('nom_descuentos', p_id, 'update', (case when p_pausar then 'Pausó' else 'Reanudó' end) || ' parcialidades: ' || trim(p_motivo), null);
  return jsonb_build_object('ok', true);
end $$;

-- Finiquito: liquida el saldo completo de los préstamos; reabrir lo revierte
alter table public.nom_descuento_pagos add column if not exists cuotas_aplicadas int default 1;

create or replace function public.nom_nomina_autorizar(p_token text, p_pin text, p_nomina uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare f record; n public.nom_nominas; r record; d jsonb; v_ent uuid; v_rs uuid; v_fid uuid; v_modo text;
  v_desc text; v_per text; v_det text := ''; v_n int := 0; v_cuotas int;
begin
  f := public.nom__firmar(p_token, p_pin, 3);
  if f.err is not null then return jsonb_build_object('ok', false, 'error', f.err); end if;
  select * into n from public.nom_nominas where id = p_nomina for update;
  if n.id is null or n.estado <> 'revisada' then return jsonb_build_object('ok', false, 'error', 'no_revisada'); end if;
  if not exists (select 1 from public.nom_recibos where nomina_id = p_nomina) then return jsonb_build_object('ok', false, 'error', 'sin_recibos'); end if;

  select id into v_ent from public.fin_entidades where nombre = 'NÓMINA COE' limit 1;
  if v_ent is null then
    insert into public.fin_entidades (nombre, tipo, categoria, activo, no_factura, dias_credito, notas)
    values ('NÓMINA COE', 'proveedor', 'Nómina', true, true, 0, 'Generado por COE Nómina') returning id into v_ent;
  end if;
  select id into v_rs from public.fin_razones_sociales where activo order by created_at limit 1;
  v_modo := coalesce((select valor->>'egreso_modo' from public.nom_config where clave = 'reglas'), 'por_empleado');
  v_per := case n.tipo when 'ordinaria' then 'Nómina ' when 'aguinaldo' then 'Aguinaldo ' when 'finiquito' then 'Finiquito ' else 'Pago extraordinario ' end
           || to_char(n.fecha_ini, 'DD/MM') || '–' || to_char(n.fecha_fin, 'DD/MM/YYYY') || ' · ' || n.folio;

  for r in select x.*, e.nombre, e.clabe, e.banco, e.forma_pago from public.nom_recibos x join public.nom_empleados e on e.id = x.empleado_id
           where x.nomina_id = p_nomina order by e.nombre loop
    v_det := v_det || r.nombre || ': $' || to_char(r.neto, 'FM999,999,990.00') || E'\n';
    if v_modo = 'por_empleado' and r.neto > 0 then
      insert into public.fin_facturas (tipo, tipo_movimiento, entidad_id, descripcion, categoria, monto_total, monto_pagado,
        fecha_vencimiento, estado, notas, created_by, updated_by, razon_social_id, sede, origen, origen_id, documento_tipo,
        factura_pendiente, clabe_proveedor, firma1_por, firma1_at, aprobado_por, aprobado_at)
      values ('egreso', 'normal', v_ent, v_per || ' · ' || r.nombre, 'Nómina', r.neto, 0, n.fecha_pago, 'pendiente',
        'Pago por ' || coalesce(r.forma_pago, 'transferencia') || coalesce(' · ' || r.banco, ''), (f.u).id, (f.u).id, v_rs, n.sede,
        'nomina', p_nomina::text, 'sin_factura', false, r.clabe, (f.u).id, now(), (f.u).nombre, now())
      returning id into v_fid;
      update public.nom_recibos set egreso_id = v_fid where id = r.id;
    end if;
    -- parcialidades de préstamos/descuentos incluidas en el recibo
    for d in select * from jsonb_array_elements(coalesce(r.detalle->'deducciones', '[]')) loop
      if nullif(d->>'descuento_id','') is not null then
        select greatest(1, case when coalesce((d->>'liquida')::boolean, false) then cuotas_total - cuotas_pagadas else 1 end)
          into v_cuotas from public.nom_descuentos where id = (d->>'descuento_id')::uuid;
        insert into public.nom_descuento_pagos (descuento_id, empleado_id, monto, fecha_pago, nomina_id, cuotas_aplicadas)
        values ((d->>'descuento_id')::uuid, r.empleado_id, (d->>'monto')::numeric, n.fecha_pago, p_nomina, v_cuotas);
        update public.nom_descuentos set cuotas_pagadas = cuotas_pagadas + v_cuotas,
          activo = (cuotas_pagadas + v_cuotas) < cuotas_total where id = (d->>'descuento_id')::uuid;
      end if;
    end loop;
    v_n := v_n + 1;
  end loop;

  if v_modo <> 'por_empleado' then
    insert into public.fin_facturas (tipo, tipo_movimiento, entidad_id, descripcion, categoria, monto_total, monto_pagado,
      fecha_vencimiento, estado, notas, created_by, updated_by, razon_social_id, sede, origen, origen_id, documento_tipo,
      factura_pendiente, firma1_por, firma1_at, aprobado_por, aprobado_at)
    values ('egreso', 'normal', v_ent, v_per || ' · ' || v_n || ' empleados', 'Nómina', n.neto, 0, n.fecha_pago, 'pendiente',
      v_det, (f.u).id, (f.u).id, v_rs, n.sede, 'nomina', p_nomina::text, 'sin_factura', false, (f.u).id, now(), (f.u).nombre, now())
    returning id into v_fid;
    update public.nom_recibos set egreso_id = v_fid where nomina_id = p_nomina;
  end if;

  if n.tipo = 'ordinaria' then
    update public.nom_incidencias i set nomina_id = p_nomina
     where i.nomina_id is null and not i.anulada and i.fecha between n.fecha_ini and n.fecha_fin
       and i.empleado_id in (select empleado_id from public.nom_recibos where nomina_id = p_nomina);
  end if;
  update public.nom_movimientos m set nomina_id = p_nomina
   where m.nomina_id is null and not m.anulada and m.id in (
     select (x->>'movimiento_id')::uuid from public.nom_recibos rr,
       jsonb_array_elements(coalesce(rr.detalle->'percepciones','[]') || coalesce(rr.detalle->'deducciones','[]')) x
      where rr.nomina_id = p_nomina and nullif(x->>'movimiento_id','') is not null);

  update public.nom_nominas set estado = 'autorizada', autorizada_por = (f.u).id, autorizada_at = now() where id = p_nomina;
  return jsonb_build_object('ok', true, 'recibos', v_n);
end $$;

create or replace function public.nom_nomina_reabrir(p_token text, p_pin text, p_pin2 text, p_nomina uuid, p_motivo text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare f record; g record; n public.nom_nominas; p record;
begin
  f := public.nom__firmar(p_token, p_pin, 2);
  if f.err is not null then return jsonb_build_object('ok', false, 'error', f.err); end if;
  if coalesce(trim(p_motivo), '') = '' then return jsonb_build_object('ok', false, 'error', 'motivo'); end if;
  select * into n from public.nom_nominas where id = p_nomina for update;
  if n.id is null or n.estado <> 'autorizada' then return jsonb_build_object('ok', false, 'error', 'estado'); end if;
  if exists (select 1 from public.fin_facturas where origen = 'nomina' and origen_id = p_nomina::text
              and not coalesce(anulado,false) and coalesce(monto_pagado,0) > 0) then
    return jsonb_build_object('ok', false, 'error', 'con_pagos');
  end if;
  g := public.nom__segunda(f.u, p_pin2);
  if g.err is not null then return jsonb_build_object('ok', false, 'error', g.err); end if;
  update public.fin_facturas set anulado = true, anulado_motivo = 'Nómina reabierta: ' || trim(p_motivo), anulado_por = (f.u).id,
    anulado_at = now(), estado = 'cancelado' where origen = 'nomina' and origen_id = p_nomina::text and not coalesce(anulado,false);
  for p in select * from public.nom_descuento_pagos where nomina_id = p_nomina loop
    update public.nom_descuentos set cuotas_pagadas = greatest(cuotas_pagadas - coalesce(p.cuotas_aplicadas, 1), 0), activo = not coalesce(anulado,false) where id = p.descuento_id;
  end loop;
  delete from public.nom_descuento_pagos where nomina_id = p_nomina;
  update public.nom_incidencias set nomina_id = null where nomina_id = p_nomina;
  update public.nom_movimientos set nomina_id = null where nomina_id = p_nomina;
  update public.nom_recibos set egreso_id = null where nomina_id = p_nomina;
  update public.nom_nominas set estado = 'observada', autorizada_por = null, autorizada_at = null,
    revision_nota = 'Reabierta: ' || trim(p_motivo) || ' · 2a firma: ' || (g.d).nombre where id = p_nomina;
  return jsonb_build_object('ok', true);
end $$;
