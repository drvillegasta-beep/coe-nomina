-- COE Nómina 2.0 · Recibos firmados (nómina, honorarios, descuentos, préstamos, eventualidades)
create table if not exists public.nom_firmados (
  id uuid primary key default gen_random_uuid(),
  categoria text not null check (categoria in ('nomina','honorarios','descuento','prestamo','eventualidad')),
  empleado_id uuid references public.nom_empleados(id),
  ref_id uuid,                -- recibo, movimiento o préstamo al que corresponde (si aplica)
  nomina_id uuid,
  fecha_ini date, fecha_fin date, fecha_firma date,
  concepto text, monto numeric,
  url text not null, sha256 text, archivo text,
  subido_por uuid, created_at timestamptz not null default now(),
  anulado boolean not null default false, anulado_motivo text, anulado_por uuid, anulado_at timestamptz
);
create index if not exists nom_firmados_ref on public.nom_firmados(ref_id);
create index if not exists nom_firmados_emp on public.nom_firmados(empleado_id, categoria);
alter table public.nom_firmados enable row level security;   -- sin políticas: solo se accede por las funciones de abajo

create or replace function public.nom_firmados_listar(p_token text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s record;
begin
  s := public.nom__sesion(p_token);
  if s.err is not null then return jsonb_build_object('ok', false, 'error', s.err); end if;
  return jsonb_build_object('ok', true, 'data',
    (select coalesce(jsonb_agg(to_jsonb(f) order by f.created_at desc), '[]') from public.nom_firmados f where not f.anulado));
end $$;

create or replace function public.nom_firmado_guardar(p_token text, p_pin text, p_datos jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare f record; v_id uuid; v_cat text := p_datos->>'categoria'; v_ref uuid := nullif(p_datos->>'ref_id','')::uuid;
begin
  f := public.nom__firmar(p_token, p_pin, 2);
  if f.err is not null then return jsonb_build_object('ok', false, 'error', f.err); end if;
  if v_cat not in ('nomina','honorarios','descuento','prestamo','eventualidad') then return jsonb_build_object('ok', false, 'error', 'categoria'); end if;
  if coalesce(p_datos->>'url','') = '' then return jsonb_build_object('ok', false, 'error', 'archivo'); end if;
  if nullif(p_datos->>'empleado_id','') is null then return jsonb_build_object('ok', false, 'error', 'usuario'); end if;
  if coalesce(p_datos->>'sha256','') <> '' and exists (select 1 from public.nom_firmados x where not x.anulado and x.sha256 = p_datos->>'sha256' and x.categoria = v_cat and x.empleado_id = (p_datos->>'empleado_id')::uuid) then
    return jsonb_build_object('ok', false, 'error', 'duplicado');
  end if;
  insert into public.nom_firmados (categoria, empleado_id, ref_id, nomina_id, fecha_ini, fecha_fin, fecha_firma, concepto, monto, url, sha256, archivo, subido_por)
  values (v_cat, (p_datos->>'empleado_id')::uuid, v_ref, nullif(p_datos->>'nomina_id','')::uuid,
          nullif(p_datos->>'fecha_ini','')::date, nullif(p_datos->>'fecha_fin','')::date, nullif(p_datos->>'fecha_firma','')::date,
          nullif(trim(p_datos->>'concepto'),''), nullif(p_datos->>'monto','')::numeric,
          p_datos->>'url', p_datos->>'sha256', p_datos->>'archivo', (f.u).id)
  returning id into v_id;
  perform public.nom__log('nom_firmados', v_id, 'insert', 'Recibo firmado (' || v_cat || ')', p_datos - 'url');
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

create or replace function public.nom_firmado_anular(p_token text, p_pin text, p_id uuid, p_motivo text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare f record;
begin
  f := public.nom__firmar(p_token, p_pin, 3);
  if f.err is not null then return jsonb_build_object('ok', false, 'error', f.err); end if;
  if coalesce(trim(p_motivo),'') = '' then return jsonb_build_object('ok', false, 'error', 'motivo'); end if;
  update public.nom_firmados set anulado = true, anulado_motivo = trim(p_motivo), anulado_por = (f.u).id, anulado_at = now() where id = p_id and not anulado;
  if not found then return jsonb_build_object('ok', false, 'error', 'usuario'); end if;
  perform public.nom__log('nom_firmados', p_id, 'update', 'Recibo firmado anulado', jsonb_build_object('motivo', p_motivo));
  return jsonb_build_object('ok', true);
end $$;

grant execute on function public.nom_firmados_listar(text) to anon, authenticated;
grant execute on function public.nom_firmado_guardar(text, text, jsonb) to anon, authenticated;
grant execute on function public.nom_firmado_anular(text, text, uuid, text) to anon, authenticated;
