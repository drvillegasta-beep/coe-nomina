-- ═══════════════════════════════════════════════════════════════════════
-- COE Nómina 2.0 · Ajustes 2 (aditivo; correr DESPUÉS de nom2_ajustes.sql)
-- · Modalidad de empleo: contrato (indeterminado, determinado, prueba) u honorarios
-- · Prestaciones por empleado (días de aguinaldo, prima vacacional, vacaciones extra)
-- · Contratos: incidencias de la quincena anterior (pago retroactivo); un solo egreso
--   de dispersión bancaria en COE Finanzas
-- · Honorarios: egreso por persona (proveedor) con factura pendiente para la Contadora
-- ═══════════════════════════════════════════════════════════════════════

alter table public.nom_empleados add column if not exists modalidad text;
alter table public.nom_empleados add column if not exists fecha_fin_contrato date;
alter table public.nom_empleados add column if not exists entidad_id uuid references public.fin_entidades(id);
alter table public.nom_empleados add column if not exists dias_aguinaldo int;
alter table public.nom_empleados add column if not exists prima_vacacional numeric;
alter table public.nom_empleados add column if not exists vac_extra int;
update public.nom_empleados set modalidad = case when esquema = 'honorarios' then 'honorarios' else 'indeterminado' end where modalidad is null;
alter table public.nom_empleados drop constraint if exists nom_empleados_modalidad_check;
alter table public.nom_empleados add constraint nom_empleados_modalidad_check check (modalidad in ('indeterminado','determinado','prueba','honorarios'));

update public.nom_config set valor = jsonb_build_object('retroactivo_contrato', true) || valor where clave = 'reglas';

-- Fechas ya pagadas: por recibo, según el periodo de asistencia que aplicó (contratos = quincena anterior)
create or replace function public.nom__bloqueado(p_emp uuid, p_fecha date) returns boolean
language sql stable security definer set search_path to 'public' as $$
  select exists (select 1 from public.nom_recibos r join public.nom_nominas n on n.id = r.nomina_id
                  where r.empleado_id = p_emp and n.estado = 'autorizada' and n.tipo = 'ordinaria'
                    and p_fecha between coalesce((r.detalle->'asistencia_periodo'->>'ini')::date, n.fecha_ini)
                                    and coalesce((r.detalle->'asistencia_periodo'->>'fin')::date, n.fecha_fin))
$$;
revoke execute on function public.nom__bloqueado(uuid, date) from public, anon, authenticated;

-- Ficha del empleado (modalidad, prestaciones, inicio de labores). Cambios sensibles = doble PIN.
create or replace function public.nom_empleado_guardar(p_token text, p_pin text, p_pin2 text, p_datos jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare f record; g record; e public.nom_empleados; v_id uuid := nullif(p_datos->>'id','')::uuid;
  v_num text[] := array['salario_diario','salario_fiscal','bono_puntualidad','bono_asistencia','bono_no_fiscal','dias_aguinaldo','prima_vacacional','vac_extra'];
  v_sens text[] := array['salario_diario','salario_fiscal','bono_puntualidad','bono_asistencia','bono_no_fiscal','esquema','modalidad',
                         'banco','clabe','rfc','nss','curp','fecha_ingreso','retener_isr','retener_imss','activo','fecha_baja',
                         'dias_aguinaldo','prima_vacacional','vac_extra'];
  k text; v_cambio text[] := '{}';
begin
  f := public.nom__firmar(p_token, p_pin, 2);
  if f.err is not null then return jsonb_build_object('ok', false, 'error', f.err); end if;
  if coalesce(trim(p_datos->>'nombre'), '') = '' then return jsonb_build_object('ok', false, 'error', 'nombre'); end if;
  if p_datos ? 'modalidad' and p_datos->>'modalidad' not in ('indeterminado','determinado','prueba','honorarios') then
    return jsonb_build_object('ok', false, 'error', 'modalidad');
  end if;
  if v_id is not null then
    select * into e from public.nom_empleados where id = v_id;
    if e.id is null then return jsonb_build_object('ok', false, 'error', 'usuario'); end if;
    foreach k in array v_sens loop
      if p_datos ? k then
        if k = any(v_num) then
          if coalesce((to_jsonb(e)->>k)::numeric, 0) <> coalesce(nullif(p_datos->>k,'')::numeric, 0) then v_cambio := v_cambio || k; end if;
        elsif (to_jsonb(e)->>k) is distinct from nullif(p_datos->>k, '') then v_cambio := v_cambio || k;
        end if;
      end if;
    end loop;
    if array_length(v_cambio, 1) > 0 then
      g := public.nom__segunda(f.u, p_pin2);
      if g.err is not null then return jsonb_build_object('ok', false, 'error', g.err, 'campos', to_jsonb(v_cambio)); end if;
    end if;
  else
    insert into public.nom_empleados (nombre, activo) values (trim(p_datos->>'nombre'), true) returning id into v_id;
  end if;
  update public.nom_empleados set
    nombre = trim(p_datos->>'nombre'),
    puesto = coalesce(p_datos->>'puesto', puesto),
    modalidad = coalesce(nullif(p_datos->>'modalidad',''), modalidad, 'indeterminado'),
    esquema = case when coalesce(nullif(p_datos->>'modalidad',''), modalidad) = 'honorarios' then 'honorarios'
                   when coalesce(nullif(p_datos->>'esquema',''), esquema) = 'comisiones' then 'comisiones' else 'fijo' end,
    periodicidad = 'quincenal',
    salario_diario = coalesce(nullif(p_datos->>'salario_diario','')::numeric, salario_diario),
    salario_base = coalesce(nullif(p_datos->>'salario_diario','')::numeric * 15, salario_base),
    salario_fiscal = case when p_datos ? 'salario_fiscal' then nullif(p_datos->>'salario_fiscal','')::numeric else salario_fiscal end,
    bono_puntualidad = case when p_datos ? 'bono_puntualidad' then coalesce(nullif(p_datos->>'bono_puntualidad','')::numeric, 0) else bono_puntualidad end,
    bono_asistencia = case when p_datos ? 'bono_asistencia' then coalesce(nullif(p_datos->>'bono_asistencia','')::numeric, 0) else bono_asistencia end,
    bono_no_fiscal = case when p_datos ? 'bono_no_fiscal' then coalesce(nullif(p_datos->>'bono_no_fiscal','')::numeric, 0) else bono_no_fiscal end,
    dias_aguinaldo = case when p_datos ? 'dias_aguinaldo' then nullif(p_datos->>'dias_aguinaldo','')::int else dias_aguinaldo end,
    prima_vacacional = case when p_datos ? 'prima_vacacional' then nullif(p_datos->>'prima_vacacional','')::numeric else prima_vacacional end,
    vac_extra = case when p_datos ? 'vac_extra' then nullif(p_datos->>'vac_extra','')::int else vac_extra end,
    fecha_ingreso = case when p_datos ? 'fecha_ingreso' then nullif(p_datos->>'fecha_ingreso','')::date else fecha_ingreso end,
    fecha_fin_contrato = case when p_datos ? 'fecha_fin_contrato' then nullif(p_datos->>'fecha_fin_contrato','')::date else fecha_fin_contrato end,
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

-- Autorizar (Director):
--   Contratos  → un egreso "Dispersión de nómina" (pago con la plantilla del banco; comprobante = transferencia)
--   Honorarios → un egreso por persona, a su nombre como proveedor, con factura pendiente (Facturas por solicitar)
create or replace function public.nom_nomina_autorizar(p_token text, p_pin text, p_nomina uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare f record; n public.nom_nominas; r record; d jsonb; v_ent uuid; v_rs uuid; v_fid uuid; v_per text; v_det text := '';
  v_n int := 0; v_nc int := 0; v_tot numeric := 0; v_cuotas int; v_lim date; v_ep uuid; v_gid uuid;
begin
  f := public.nom__firmar(p_token, p_pin, 3);
  if f.err is not null then return jsonb_build_object('ok', false, 'error', f.err); end if;
  select * into n from public.nom_nominas where id = p_nomina for update;
  if n.id is null or n.estado <> 'revisada' then return jsonb_build_object('ok', false, 'error', 'no_revisada'); end if;
  if not exists (select 1 from public.nom_recibos where nomina_id = p_nomina) then return jsonb_build_object('ok', false, 'error', 'sin_recibos'); end if;

  select id into v_ent from public.fin_entidades where nombre = 'NÓMINA COE' limit 1;
  if v_ent is null then
    insert into public.fin_entidades (nombre, tipo, categoria, activo, no_factura, dias_credito, notas)
    values ('NÓMINA COE', 'proveedor', 'Nómina', true, true, 0, 'Dispersión de nómina (contratos). Generado por COE Nómina') returning id into v_ent;
  end if;
  select id into v_rs from public.fin_razones_sociales where activo order by created_at limit 1;
  v_lim := (date_trunc('month', n.fecha_pago) + interval '1 month - 1 day')::date;
  v_per := to_char(n.fecha_ini, 'DD/MM') || '–' || to_char(n.fecha_fin, 'DD/MM/YYYY') || ' · ' || n.folio;

  for r in select x.*, e.nombre, e.clabe, e.banco, e.rfc, e.email, e.telefono, e.forma_pago, e.entidad_id,
                  coalesce(e.modalidad, case when e.esquema = 'honorarios' then 'honorarios' else 'indeterminado' end) as modalidad
             from public.nom_recibos x join public.nom_empleados e on e.id = x.empleado_id
            where x.nomina_id = p_nomina order by e.nombre loop
    if r.modalidad = 'honorarios' then
      if r.neto > 0 then
        v_ep := r.entidad_id;
        if v_ep is null or not exists (select 1 from public.fin_entidades where id = v_ep) then
          insert into public.fin_entidades (nombre, tipo, categoria, activo, no_factura, dias_credito, rfc, clabe, banco, email, telefono, titular_cuenta, notas)
          values (r.nombre, 'proveedor', 'Honorarios', true, false, 0, r.rfc, r.clabe, r.banco, r.email, r.telefono, r.nombre, 'Prestador de servicios profesionales (honorarios). Generado por COE Nómina')
          returning id into v_ep;
          update public.nom_empleados set entidad_id = v_ep where id = r.empleado_id;
        end if;
        insert into public.fin_facturas (tipo, tipo_movimiento, entidad_id, descripcion, categoria, monto_total, monto_pagado,
          fecha_vencimiento, estado, notas, created_by, updated_by, razon_social_id, sede, origen, origen_id, documento_tipo,
          factura_pendiente, factura_limite, clabe_proveedor, metodo_pago, firma1_por, firma1_at, aprobado_por, aprobado_at)
        values ('egreso', 'normal', v_ep, 'Honorarios ' || v_per, 'Honorarios', r.neto, 0, n.fecha_pago, 'pendiente',
          'Pago por transferencia' || coalesce(' · ' || r.banco, '') || '. Debe entregar factura por ' || to_char(r.neto, 'FM$999,999,990.00'),
          (f.u).id, (f.u).id, v_rs, n.sede, 'nomina', p_nomina::text, 'sin_factura', true, v_lim, r.clabe, 'PUE',
          (f.u).id, now(), (f.u).nombre, now())
        returning id into v_fid;
        update public.nom_recibos set egreso_id = v_fid where id = r.id;
      end if;
    else
      v_det := v_det || r.nombre || ': ' || to_char(r.neto, 'FM$999,999,990.00') || coalesce(' · ' || r.banco, '') || coalesce(' · CLABE ' || r.clabe, ' · sin CLABE') || E'\n';
      v_tot := v_tot + r.neto; v_nc := v_nc + 1;
    end if;
    -- parcialidades de préstamos incluidas en el recibo (el finiquito liquida el saldo completo)
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
    -- incidencias aplicadas en este recibo (contratos: periodo anterior)
    if n.tipo = 'ordinaria' then
      update public.nom_incidencias i set nomina_id = p_nomina
       where i.nomina_id is null and not i.anulada and i.empleado_id = r.empleado_id
         and i.fecha between coalesce((r.detalle->'asistencia_periodo'->>'ini')::date, n.fecha_ini)
                         and coalesce((r.detalle->'asistencia_periodo'->>'fin')::date, n.fecha_fin);
    end if;
    v_n := v_n + 1;
  end loop;

  if v_nc > 0 and v_tot > 0 then
    insert into public.fin_facturas (tipo, tipo_movimiento, entidad_id, descripcion, categoria, monto_total, monto_pagado,
      fecha_vencimiento, estado, notas, created_by, updated_by, razon_social_id, sede, origen, origen_id, documento_tipo,
      factura_pendiente, metodo_pago, firma1_por, firma1_at, aprobado_por, aprobado_at)
    values ('egreso', 'normal', v_ent,
      case n.tipo when 'aguinaldo' then 'Aguinaldo ' when 'finiquito' then 'Finiquito ' when 'extraordinaria' then 'Pago extraordinario ' else 'Dispersión de nómina ' end
        || v_per || ' · ' || v_nc || ' empleado(s)', 'Nómina', v_tot, 0, n.fecha_pago, 'pendiente',
      'Pago con la plantilla del banco (transferencia de nómina). Comprobante: la transferencia.' || E'\n' || v_det,
      (f.u).id, (f.u).id, v_rs, n.sede, 'nomina', p_nomina::text, 'sin_factura', false, 'PUE', (f.u).id, now(), (f.u).nombre, now())
    returning id into v_gid;
    update public.nom_recibos x set egreso_id = v_gid from public.nom_empleados e
     where x.nomina_id = p_nomina and e.id = x.empleado_id
       and coalesce(e.modalidad, case when e.esquema = 'honorarios' then 'honorarios' else 'indeterminado' end) <> 'honorarios';
  end if;

  update public.nom_movimientos m set nomina_id = p_nomina
   where m.nomina_id is null and not m.anulada and m.id in (
     select (x->>'movimiento_id')::uuid from public.nom_recibos rr,
       jsonb_array_elements(coalesce(rr.detalle->'percepciones','[]') || coalesce(rr.detalle->'deducciones','[]')) x
      where rr.nomina_id = p_nomina and nullif(x->>'movimiento_id','') is not null);

  update public.nom_nominas set estado = 'autorizada', autorizada_por = (f.u).id, autorizada_at = now() where id = p_nomina;
  return jsonb_build_object('ok', true, 'recibos', v_n, 'contrato', v_nc, 'honorarios', v_n - v_nc);
end $$;

-- Lectura: el estado de cada egreso incluye si la factura de honorarios sigue pendiente
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
                 'pagado', f.monto_pagado, 'anulado', coalesce(f.anulado, false), 'fecha_pago', f.fecha_pago,
                 'factura_pendiente', coalesce(f.factura_pendiente, false), 'factura_limite', f.factura_limite, 'con_xml', f.xml_url is not null)), '[]')
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
