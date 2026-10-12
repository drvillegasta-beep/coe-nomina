# COE Nómina 2.0

- `coe-nomina.html`: app nueva (usuarios de COE Finanzas, checador, cálculo, prestaciones, envío a Finanzas).
- `coe-nomina-v1.html`: versión anterior, se conserva mientras se hace el cambio.
- `sql/nom2_deploy.sql`: **el que se corre** en el editor SQL de Supabase (un solo archivo, versión final).
- `sql/nom2_completo.sql`: correr una vez en Supabase antes de usar la app nueva (incluye ajustes y ajustes2).
- `sql/nom2_ajustes2.sql`: solo si ya se había corrido una versión anterior del SQL.
- `sql/nom2_cerrar_v1.sql`: correr solo cuando la v1 ya no se use.
