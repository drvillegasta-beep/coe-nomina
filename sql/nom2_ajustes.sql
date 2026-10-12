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
