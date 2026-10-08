# Canal mandibular — DentalViewer 0.5.7

## Datos originales de Xelis

La posición del canal está guardada en el estudio. DentalViewer la lee directamente: no usa Docker, redes neuronales, segmentación automática ni búsqueda por intensidad. Se quitaron los motores y sus recursos del proyecto y de la aplicación.

El archivo de proyecto `.XPV` contiene el índice de los archivos. La geometría está en el DICOM de proyecto asociado, en el bloque privado `(7573,1004)` del creador `MEVISYS`. El DICOM también contiene una imagen JPEG de presentación; sus datos privados pueden leerse independientemente de esa imagen.

El bloque privado contiene un ZIP con una entrada `-`. Se descomprime con zlib del sistema y se verifica CRC y longitudes. El payload guarda registros tipados de curva y una colección de canales con cantidad, identificadores y versión. Su clasificación usa esa colección, no la ubicación ni la intensidad de los puntos.

Compatibilidad inicial: `Lucion 1.0.6.4 BN2(P)`, snapshot `30000001`, payload `30000017`, curvas `CCurveStrider2` versión `10000002`, colección de canales versión `10000001` y cabecera general de curva `10000003`. La implementación solo admite esta estructura verificada; no implica compatibilidad universal con XPV.

### Correspondencia física

Los metadatos privados `(7573,1003)` referencian los SOP Instance UID de todos los cortes del CT. Deben coincidir exactamente con los cortes abiertos y el Study Instance UID. Se validan los límites locales guardados y la geometría axial LPS de la serie. Las posiciones locales en milímetros se trasladan al origen físico DICOM; no se realiza registro, estimación de anatomía ni ajuste de la curva.

Se recuperan la curva dental y los canales originales, incluidas sus muestras, controles y marcos de sección. Los recuentos y coordenadas de estudios privados no se distribuyen con el código.

Se conservan las posiciones, controles y ejes guardados. La última muestra densa no necesariamente coincide con el último control en el formato original: se conserva tal como está. Los puntos de control se verifican contra sus índices de marcos guardados. No se simplifica ni se suaviza el canal importado.

## Visualización y revisión

Los canales originales aparecen en verde en 3D, planos MPR y transversales. La panorámica muestra su proyección sobre el arco original. Su espesor gráfico de 1.3 mm es únicamente un estilo de visualización: no se interpreta como diámetro anatómico ni como un parámetro importado. Se utiliza una malla gráfica de cada segmento guardado; el límite manual de 256 elementos no recorta los trazados originales.

En **Canal mandibular**, elegí **Canal original 1/2**: cambia inmediatamente el punto de referencia y, si está abierta, la revisión del trazado elegido. El título identifica cuál se revisa. Panorámica y 3D muestran ambos juntos; el selector no oculta el otro. Controlá **Mostrar canales originales** o usá **Recorrer canal original**. La revisión perpendicular/longitudinal recorre la polilínea guardada y sincroniza los cortes. La interpolación para generar imágenes de revisión no crea posiciones anatómicas nuevas del canal.

La vista dental conserva el arco original y sus ejes inclinados para reformatear las imágenes. No se ofrece arrastrar sus puntos como si fueran una curva estimada. Un estudio sin proyecto compatible comienza sin curva: puede definirse manualmente en axial.

## Trazado manual y persistencia

Los canales manuales son independientes de los originales. Admiten crear, seleccionar, mover, insertar y borrar puntos; nombre, lado, color, visibilidad y diámetro gráfico; deshacer/rehacer, curva suave opcional y revisión. El suavizado solo se aplica cuando el usuario lo activa en un trazado manual. Los clics y arrastres funcionan en axial, MPR, panorámica y transversales, incluidos los paneles ampliados. En panorámica se colocan sobre la superficie de la profundidad mostrada; en transversales, sobre el plano guardado. Al editar un punto existente en transversal se conserva su distancia normal al plano. Cada arrastre se deshace como una sola acción.

Los implantes siguen siendo cilindros genéricos. Las distancias implante/trazado actuales usan canales manuales; no incluyen todavía los originales importados. No se les atribuye una distancia clínica segura.

Guardar un `.dentalplan.json` conserva la planificación manual, no reemplaza ni modifica el DICOM de Xelis. Al abrir el estudio se recuperan nuevamente los canales originales. No se escribe XPV ni se promete restaurar todas las anotaciones, máscaras o propiedades de presentación de Xelis. Si no hay un proyecto compatible, se informa y no se genera un canal.
