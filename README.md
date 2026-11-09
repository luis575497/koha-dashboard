# Dashboard bibliotecario para Koha

Plugin de herramientas para **Koha 24.05 o posterior**. Reúne métricas de circulación, colección, usuarios, atrasos, reservas y catalogación en pestañas. Permite filtrar por biblioteca y fechas, explorar tablas y exportar CSV.

## Qué incorpora

- **Separación de material y equipos:** en **Plugins → Configurar** se seleccionan los tipos de ítem que representan cargadores, audífonos, calculadoras u otros equipos. Esos tipos salen del porcentaje de títulos usados, de los tops bibliográficos, de los reportes de ejemplares sin movimiento, de la rotación bibliográfica y del KPI de préstamos bibliográficos. Se presentan por separado en tops y rotación de equipos. El total general de circulación incluye todos los préstamos.
- **Tendencias con contexto de datos:** los gráficos completan los meses sin eventos y los muestran como “sin datos registrados”; un mes con eventos, pero cero préstamos, queda como cero. El gráfico de 36 meses etiqueta cada seis meses. La comparación interanual usa el mismo intervalo de fechas del año previo, no el mes completo contra un mes parcial.
- **Referencia estacional limitada:** se oculta salvo que existan 36 meses consecutivos con eventos y el rango calculado no sea demasiado amplio ni llegue a cero. Usa el promedio del mismo mes de los dos años previos. Es una referencia, no una predicción validada.
- **Usuarios y privacidad:** muestra socios activos sobre socios vigentes y sobre categorías elegibles, continuidad entre períodos, y activación de nuevas inscripciones. Las categorías elegibles se configuran por la biblioteca. De forma predeterminada, los tops usan alias; los nombres completos y la exportación de vencidos con nombres requieren el permiso Koha `borrowers → edit_borrowers`.
- **Colección accionable:** mapas de calor de ejemplares sin préstamos en 1, 3 o 5 años y préstamos por clasificación. Cada cuadro representa un prefijo del tejuelo; tonos más intensos representan más ejemplares o préstamos. El prefijo no siempre equivale a Dewey/CDU. Ambos informes conservan exportación CSV.
- **Operación y metas:** atrasos por antigüedad, lista CSV de vencidos para personal autorizado, reservas pendientes y antigüedad media de la cola, comparación entre bibliotecas, meta configurable de préstamos y alerta si los préstamos caen al menos 20% frente al período anterior de igual duración.
- **Búsquedas sin resultados:** términos bibliográficos que se repitieron al menos dos veces sin resultados, si Koha conserva el historial OPAC. Esta métrica es global: Koha no registra la sucursal en `search_history`.
- **Impresión:** el botón “Imprimir / Guardar PDF” abre la impresión del navegador, donde se puede guardar como PDF.

Las tablas incluyen búsqueda local y orden por columna. El uso en sala cuenta solo si la biblioteca registra eventos `localuse`; no equivale a visitas de personas.

## Configuración

Desde **Plugins → Configurar** se pueden definir:

1. Tipos de ítem no bibliográficos.
2. Categorías de socios elegibles (por ejemplo, categorías que representen una matrícula vigente).
3. Una meta de préstamos para el rango consultado.

Si no se seleccionan categorías elegibles, el denominador usa todas las fichas de socio no vencidas. Koha no puede conocer la vigencia académica si la biblioteca no la expresa en categorías o en un campo actualizado.

La configuración del plugin requiere el permiso Koha `configure`. El formulario incluye el token CSRF requerido por Koha para guardar cambios. Para instalarlo, el servidor debe tener habilitado el sistema de plugins.

## Indicadores y límites

- **Cobertura de la colección** = títulos distintos con al menos un préstamo ÷ títulos distintos con ejemplares, multiplicado por 100. Los equipos configurados quedan fuera.
- **Rotación por tipo** = préstamos ÷ ejemplares para ese tipo de ítem en el período.
- **Socios activos** tienen al menos un préstamo o renovación registrados. Los porcentajes actuales consideran fichas no vencidas y, para la tasa elegible, las categorías seleccionadas.
- “Sin préstamos” significa sin un evento de préstamo encontrado en el período consultado. No determina por sí solo que un ítem deba descartarse.
- Las comparaciones por sucursal usan la biblioteca de transacción; los préstamos de catalogación se atribuyen a la biblioteca principal del personal.
- La anonimización del historial puede reducir la cobertura de las métricas de usuarios. La anonimización de nombres del dashboard se aplica al mostrar datos; no cambia la política de conservación de Koha.
- Las búsquedas OPAC requieren que la preferencia `EnableOpacSearchHistory` conserve el historial. Solo se presentan frases frecuentes, sin identificadores de usuario.
- El plugin no puede inferir visitas físicas, población atendida, uso de recursos electrónicos, satisfacción, facultad/carrera si esos campos no están disponibles, ni personal/horarios/costos. Se requieren conteos o integraciones adicionales.
- No programa envíos de correo; requiere configurar y aprobar una vía de envío en el servidor.

## Instalar y actualizar

1. Descarga el KPZ de [`releases/`](releases/).
2. En Koha, ve a **Herramientas → Plugins**, carga el archivo y habilítalo si aparece desactivado.
3. Ejecuta el plugin y ajusta los tipos de ítem/categorías elegibles desde **Plugins → Configurar**.

Conserva el KPZ previo antes de reemplazar una instalación en producción.

## Crear el KPZ

Requiere `zip`. Desde la raíz del repositorio:

```sh
./build-kpz.sh
```

Genera `releases/koha-dashboard-bibliotecario-v1.7.0.kpz`.

## Privacidad

Los nombres de prestatarios, catalogadores y personas vencidas solo se devuelven si el usuario actual tiene el permiso `borrowers → edit_borrowers`; en el resto de casos se muestran alias anónimos. El plugin consulta Koha localmente y no envía información a servicios externos.

## Licencia

GPL-3.0-or-later.
