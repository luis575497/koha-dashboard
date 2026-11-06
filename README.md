# Dashboard bibliotecario para Koha

Plugin de herramientas para **Koha 24.05 o posterior**. Reúne en una sola pantalla indicadores de circulación, movimiento de colección, préstamos vencidos, multas, usuarios y catalogación. Está pensado para que el personal bibliotecario pueda revisar la actividad de la colección y comparar períodos sin construir informes SQL por separado.

## Qué muestra

- **Circulación:** préstamos, renovaciones y devoluciones por mes; préstamos por día de la semana y hora; diez títulos más prestados.
- **Movimiento de títulos:** porcentaje de títulos distintos prestados durante el período respecto al total de títulos distintos que tienen ejemplares en la colección filtrada. Fórmula: `títulos distintos prestados ÷ títulos distintos en colección × 100`.
- **Comparación temporal:** préstamos del período actual frente a un período anterior de igual duración.
- **Colección:** cantidad de ejemplares y títulos, ejemplares sin préstamos en el rango elegido, y rotación por tipo de ítem.
- **Atrasos y multas:** préstamos vencidos actuales por tramos de antigüedad; multas por atraso generadas, recuperadas y pendientes.
- **Usuarios:** socios vigentes, usuarios activos, socios activos por categoría, incorporaciones por mes y la persona con más préstamos en el período.
- **Catalogación:** registros bibliográficos añadidos por mes y personal con más altas de registros.

Los paneles se pueden filtrar por biblioteca y por uno, tres, seis o doce meses, o por un rango personalizado. Los indicadores que muestran tablas o series ofrecen exportación CSV.

## Instalar en Koha

1. Descarga el archivo KPZ desde [releases](releases/).
2. En el intranet de Koha, abre **Herramientas → Plugins** y carga el KPZ.
3. Habilita el plugin si Koha lo deja desactivado y ejecútalo desde la sección de herramientas de plugins.
4. Selecciona el período y la biblioteca; pulsa **Actualizar** para consultar los datos.

El servidor debe tener habilitado el sistema de plugins de Koha. Las opciones exactas pueden variar ligeramente entre versiones.

## Empaquetar desde el código

Requiere `zip`. Desde la raíz de este repositorio:

```sh
./build-kpz.sh
```

El paquete se crea en `releases/koha-dashboard-bibliotecario-v1.2.0.kpz`. El KPZ incluye el módulo Perl, la plantilla y los estilos y scripts del dashboard.

## Cómo se calculan algunos indicadores

- Los títulos de la colección son los `biblionumber` distintos que tienen al menos un ejemplar en `items`; una obra con varios ejemplares cuenta una sola vez.
- Un título se cuenta como prestado si al menos un ejemplar suyo tiene un evento `issue` en `statistics` dentro del período. Si se elige una biblioteca, el cálculo de títulos prestados filtra tanto la biblioteca de circulación como la biblioteca propietaria del ejemplar.
- La persona con más préstamos se calcula con eventos `issue` vinculados a `borrowernumber`, sin contar renovaciones. Si el historial de Koha fue anonimizado, algunos eventos antiguos ya no podrán atribuirse a una persona.
- Los usuarios activos se obtienen de eventos de préstamo o renovación en `statistics`. Las altas de registros por catalogador requieren que Koha conserve los eventos correspondientes en `action_logs`.
- La selección de biblioteca para estadísticas de catalogación se atribuye a la biblioteca principal del miembro del personal.

## Privacidad y permisos

El dashboard muestra el nombre de la persona con más préstamos; limita su consulta al período y a la biblioteca seleccionados. Por tratarse de un dato individual de uso, instala y habilita el plugin solo para personal autorizado según las políticas de privacidad de tu biblioteca. El plugin consulta los datos directamente en Koha y no los envía a servicios externos.

## Limitaciones

- El movimiento compara títulos con ejemplares, no registros bibliográficos sin holdings.
- El historial anonimizado limita los recuentos que dependen de identificar a la persona prestataria.
- La rotación y los resultados históricos dependen de los eventos que Koha conserve en `statistics`.
- El tiempo de respuesta depende del tamaño de la base de datos y del rango consultado.
- El código se empaqueta para Koha 24.05 o posterior; revisa la versión y permisos locales antes de desplegarlo en producción.

## Desarrollo

El plugin usa SQL de lectura sobre las tablas de Koha y genera el dashboard en la interfaz intranet. No requiere CDN ni servicios de gráficos externos; los gráficos se dibujan como SVG. Las fechas y la biblioteca seleccionada se envían al endpoint interno del plugin para recuperar los indicadores o exportar CSV.

## Licencia

GPL-3.0-or-later.
