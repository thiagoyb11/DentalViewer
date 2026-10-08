# Funcionalidades pendientes para acercar DentalViewer a Xelis Dental

Actualizado: 8 de octubre de 2026. Aplicación: DentalViewer para macOS, prototipo 0.5.7. La disposición dental toma como referencia también la fotografía del visor original aportada por el usuario.

## Alcance de la comparación

Este inventario compara el código actual con las funciones publicadas para **Xelis Dental 2.0** y las ediciones **Basic/Advanced** comercializadas por Trident. El visor que acompaña un estudio puede ofrecer menos herramientas que esas ediciones. El 8 de octubre de 2026 se comparó en vivo la panorámica del ejecutable Windows del ejemplo en VMware Fusion, incluida su regla horizontal, vertical y diagonal. No se revisó cada herramienta ni se exportaron extremos de medición exactos: la equivalencia completa con ese ejecutable todavía debe verificarse.

El documento reúne las funciones identificadas en las referencias oficiales y los trabajos necesarios para completar nuestras implementaciones parciales. No garantiza cubrir funciones no documentadas, complementos opcionales o diferencias entre versiones.

Referencias:

- [Tutoriales oficiales de Xelis Dental 2.0, INFINITT](https://www.infinitt.com/contents/tutorial.php?ctr=a_kor&url=XelisDental2): recorrido de las herramientas y flujos de trabajo.
- [Xelis, funciones y ediciones, Trident](https://www.trident-dental.com/en/software/): prestaciones generales y diferencias entre Basic/Advanced. Usar la sección XELIS; las funciones de Deep-View, AudaxCeph y DFO son productos distintos.
- [INFINITT Dental PACS](https://www.infinitt.com/product.php?ctr=g_eng&solution=Dentistry): integración de Xelis con la plataforma dental.
- [DICOM: geometría de los planos de imagen](https://dicom.nema.org/medical/dicom/current/output/chtml/part03/sect_C.7.6.2.html): referencia técnica para posicionamiento y espaciado, no una lista de funciones de Xelis.

Estados: **Pendiente** = no disponible en la interfaz; **Parcial** = existe una versión limitada; **Implementada en prototipo** = disponible, sin equivalencia clínica validada; **Por confirmar** = debe verificarse en la edición original antes de exigir paridad. La columna «Trabajo pendiente» describe nuestro alcance propuesto, no una especificación oficial de Xelis.

## Base que ya está disponible

- Abrir carpetas del estudio y seleccionar series CT compatibles.
- Cortes axial, coronal y sagital con referencia sincronizada, zoom y desplazamiento.
- Ajustes de centro/ventana, presets, regla y medición lineal en MPR y panorámica curva.
- Superficie 3D de umbral, rotación siguiendo el mouse y zoom.
- Captura PNG de la ventana; ampliación y restauración de cada panel dentro del contenedor, incluidas secciones transversales individuales.
- Planificación manual inicial: implantes roscados genéricos, ajuste de tamaño/inclinación y posición en los cortes.
- Canales editables por puntos, con nombre, lateralidad, color, visibilidad, diámetro y curva suave; deshacer/rehacer y cortes de revisión.
- Importación directa de la curva dental y dos canales guardados en el DICOM de proyecto Xelis del ejemplo, con sus coordenadas originales; visualización verde en cortes/3D, proyección panorámica y revisión del recorrido. Sin Docker ni IA.
- Pantalla dental: mosaico de nueve transversales, panorámica curva, axial, 3D e histograma inferior; curva original recuperada o definida manualmente, y navegación sincronizada.
- Separación geométrica aproximada entre implante y trazado manual.
- Guardado y carga de implantes/canales en `.dentalplan.json`, verificando serie y geometría. El formato v2 conserva las nuevas propiedades y abre planes v1 sin cambiar sus segmentos rectos.

La importación original se detalla en [CANAL-MANDIBULAR.md](CANAL-MANDIBULAR.md). Docker, modelos de IA y búsqueda por intensidad fueron retirados según la indicación del usuario.

Estas funciones son de prototipo y no tienen validación clínica. El archivo propio no es compatible con proyectos XPV de Xelis.

## 1. Reformateo y navegación dental

Funciones de referencia: curva de arcada, panorámica, reformateo, cortes transversales/longitudinales, reposicionamiento y verificación. [INFINITT](https://www.infinitt.com/contents/tutorial.php?ctr=a_kor&url=XelisDental2), [Trident](https://www.trident-dental.com/en/software/).

| Función | Estado | Trabajo pendiente en DentalViewer |
| --- | --- | --- |
| Curva de la arcada | Parcial | Se recupera la curva y sus ejes del proyecto Xelis compatible; otros estudios permiten definición manual. Falta persistencia de curvas propias, edición completa y otras versiones de proyecto. |
| Panorámica reconstruida | Parcial | Disponible, con promedio, espesor de 0 a 10 mm, profundidad de −10 a +10 mm, referencia axial en cian, navegación sincronizada y proyección del canal original guardado. Regla en mm y barra vertical de 10 mm; escala auditada contra DICOM y distancias guardadas. Las comparaciones privadas de pantalla usan extremos aproximados y no constituyen validación clínica. Faltan controles de proyección, persistencia, numeración de secciones al estilo Xelis y validación con extremos exactos exportados en ambos visores. |
| Cortes perpendiculares a la arcada | Implementada en prototipo | Nueve secciones reales, paso de 0.5/1/2 mm, campo configurable y navegación sincronizada. Falta medición/planificación directa en estos planos y evaluación independiente. |
| Corte longitudinal | Pendiente | Crear una vista paralela al recorrido y documentar su geometría. |
| Vista de verificación de implantes | Pendiente | Generar planos alineados con el eje del implante y medir sobre ellos. |
| MPR oblicua | Pendiente | Reformatear planos arbitrarios con interpolación tridimensional y etiquetas de orientación correctas. |
| Reposicionamiento del volumen | Pendiente | Definir referencias anatómicas y transformar vistas sin alterar los DICOM originales. |
| Mosaico de cortes dentales | Parcial | Grilla 3×3 con posición en mm, selección y separación configurable. Falta configurar cantidad de filas/columnas, espesor de sección y exportación/impresión por lotes. |
| Vista bilateral de ATM | Pendiente | Preparar vistas dedicadas a cada articulación con orientación independiente. |
| Fusión de adquisiciones | Pendiente | Registrar volúmenes, manejar solapamiento y validar el resultado antes de combinar imágenes. |

## 2. Implantes

Referencia: colocación, biblioteca, listado y planificación de implantes. [INFINITT](https://www.infinitt.com/contents/tutorial.php?ctr=a_kor&url=XelisDental2), [Trident](https://www.trident-dental.com/en/software/).

| Función | Estado | Trabajo pendiente en DentalViewer |
| --- | --- | --- |
| Simulación geométrica | Parcial | Hay una malla roscada genérica con cuello, cuerpo cónico y punta redondeada, escalada en mm. MPR y transversales muestran su intersección física; la panorámica muestra una silueta proyectada. Faltan geometrías y dimensiones específicas de cada fabricante. |
| Biblioteca por fabricante/modelo | Pendiente | Conseguir catálogos y geometrías verificables; implementar búsqueda, filtros, identificación y actualización. |
| Importar biblioteca del ejemplo | Pendiente | Examinar `ImplantLib.mdb` y `.pmf`; documentar cómo interpretar modelos y metadatos. No basta con leer la base de datos. |
| Descarga/actualización de bibliotecas | Pendiente | Definir una fuente de datos autorizada y un formato de intercambio propio. No asumir acceso al servicio de Xelis. |
| Manipulación avanzada | Parcial | Agregar controles sobre el modelo 3D, selección por clic, duplicación, nombres y posicionamiento preciso. |
| Listado de implantes | Parcial | El selector actual no reemplaza una tabla de posiciones, tamaños, modelos y observaciones. |
| Información clínica del implante | Pendiente | Incorporar datos del fabricante, componentes y referencias, cuando estén disponibles. |
| Informe de planificación | Pendiente | Exportar un informe que relacione cada implante con imágenes y parámetros. |
| Planificación completa de cirugía guiada | Por confirmar | Determinar qué genera la edición original. Guías quirúrgicas, registro de superficies y datos de fabricación requieren un alcance y una validación específicos. |

## 3. Canal mandibular y relaciones geométricas

Referencia: trazado y segmentación del canal. [INFINITT](https://www.infinitt.com/contents/tutorial.php?ctr=a_kor&url=XelisDental2), [Trident](https://www.trident-dental.com/en/software/).

| Función | Estado | Trabajo pendiente en DentalViewer |
| --- | --- | --- |
| Trazado manual | Implementada en prototipo | Selección, inserción, movimiento y borrado de cualquier punto, coordenadas físicas y deshacer/rehacer. Pendiente evaluar ergonomía y precisión con usuarios y estudios de referencia. |
| Curva suave del canal | Implementada en prototipo | Interpolación Hermite acotada que conserva los puntos originales y evita sobrepasar sus límites por coordenada. Pendiente evaluación anatómica; cuatro segmentos aproximan cada intervalo suave. |
| Organización de trazados | Implementada en prototipo | Nombre, lateralidad, color y visibilidad individuales se guardan en el plan. Pendiente comparar el flujo con la edición original. |
| Canales guardados en el proyecto Xelis | Implementada en prototipo | Se leen directamente las posiciones, controles y marcos originales guardados; se verifica serie, geometría y CRC. Falta soportar otras versiones, importar todas sus propiedades y escritura compatible. |
| Segmentación automática sin referencias | Fuera del alcance solicitado | El usuario indicó usar exclusivamente trazados guardados; los modelos de IA y Docker se quitaron de la aplicación. |
| Búsqueda de recorrido por intensidad | Fuera del alcance solicitado | Se eliminó la búsqueda A*: no se infiere ni se estima la posición anatómica del canal. |
| Separación respecto al implante | Parcial | El cálculo usa segmentos y envolventes geométricas conservadoras. Identifica el par de puntos más cercano y permite revisar esa posición. Falta comparar contra superficies reales e incluir los canales originales importados. |
| Análisis de proximidad/intersección | Parcial | No hay un protocolo clínico ni umbrales de seguridad validados. No emitir una conclusión de seguridad a partir de la cifra actual. |
| Cortes de revisión del canal | Implementada en prototipo | Planos perpendicular y longitudinal locales con muestreo trilineal, campo físico ajustable, recorrido en mm y referencia sincronizada. Pendiente evaluación anatómica y comparación independiente. |

Límites actuales del prototipo: hasta 100 implantes, 10 canales y **256 elementos 3D** en total —cada implante o segmento del canal cuenta como un elemento; con curva suave cada intervalo entre puntos usa cuatro segmentos—. La representación 2D es una aproximación mediante proyección y recorte de esos elementos. La 3D muestra la planificación superpuesta al hueso para hacerla visible; no reproduce la oclusión anatómica completa.

## 4. Análisis y segmentación anatómica

Referencia: intensidad/densidad, senos, vías aéreas y volumen óseo. [INFINITT](https://www.infinitt.com/contents/tutorial.php?ctr=a_kor&url=XelisDental2), [Trident](https://www.trident-dental.com/en/software/).

| Función | Estado | Trabajo pendiente en DentalViewer |
| --- | --- | --- |
| Análisis de densidad/intensidad | Parcial | Se muestra la intensidad de un vóxel. Agregar regiones, perfiles y estadísticas; identificar qué calibración permite cada adquisición. |
| Volumen de senos | Pendiente | Definir/segmentar la región y calcular volumen físico, con revisión del contorno. |
| Análisis de vías aéreas | Pendiente | Segmentación, secciones y cuantificación; validar límites y unidades. |
| Segmentación de hueso | Pendiente | Extraer regiones de interés, revisar resultados y cuantificar volumen sin confundir umbral con diagnóstico. |
| Medición semiautomática | Pendiente | Definir los casos de uso y validar el método con datos anotados. |

La intensidad reescalada de un CBCT no demuestra, por sí sola, una densidad ósea calibrada. La precisión geométrica, la segmentación y la calibración de intensidad deben evaluarse por separado.

## 5. Medición, anotaciones y presentación

Referencia: herramientas de medición, lista de anotaciones, marcadores, presentación y personalización. [INFINITT](https://www.infinitt.com/contents/tutorial.php?ctr=a_kor&url=XelisDental2), [Trident](https://www.trident-dental.com/en/software/).

| Función | Estado | Trabajo pendiente en DentalViewer |
| --- | --- | --- |
| Medición lineal | Parcial | Disponible en axial, MPR, panorámica curva y transversales con clic/arrastre, etiqueta en mm y listado de sesión, también en paneles ampliados. La panorámica mide distancia sobre el arco desplegado y altura física; conserva la escala de columnas originales no uniformes. Los transversales usan la distancia física del plano de sección guardado. Falta seleccionar/mover mediciones existentes, borrado individual y persistencia. |
| Otras mediciones | Por confirmar | Inventariar las herramientas concretas de la edición original —ángulos, áreas, etc.— antes de especificarlas como requisito de paridad. |
| Lista de anotaciones | Parcial | Existe una lista básica de distancias en sesión; faltan anotaciones editables y navegación al plano/corte asociado. |
| Marcadores de vista | Pendiente | Guardar encuadres, parámetros y posiciones para retomarlos. |
| Presentación dinámica de imágenes | Parcial | Cada panel y sección transversal puede ampliarse dentro del contenedor y restaurarse conservando encuadre y mediciones. Falta disposición configurable, composiciones de comparación y persistencia de preferencias. |
| Barra de herramientas configurable | Pendiente | Permitir mostrar/ocultar herramientas y recordar preferencias. |
| Pestañas/vistas configurables | Pendiente | Adaptar la distribución de vistas a distintos flujos dentales. |
| Renderizado volumétrico completo | Parcial | La vista actual muestra una superficie de umbral reducida. Investigar funciones de transferencia de color/opacidad y modos equivalentes a los de la edición original. |

## 6. Informes, impresión y exportación

Referencia: informes y plantillas, captura, exportación STL, impresión por lotes, DICOM y medios externos. [INFINITT](https://www.infinitt.com/contents/tutorial.php?ctr=a_kor&url=XelisDental2), [Trident](https://www.trident-dental.com/en/software/).

| Función | Estado | Trabajo pendiente en DentalViewer |
| --- | --- | --- |
| Gestión de capturas | Parcial | Hay PNG de la ventana; agregar capturas por vista y una colección organizada por caso. |
| Informes con plantillas | Pendiente | Componer textos, imágenes, mediciones y datos de planificación; exportar documentos revisables. |
| Creación de plantillas | Pendiente | Editor y almacenamiento de plantillas reutilizables. |
| Plantillas a escala real | Pendiente | Controlar escala física al exportar/imprimir y comprobarla con medidas de referencia. |
| Informe de implantes | Pendiente | Generar tablas y vistas por implante con identificación del modelo usado. |
| Impresión por lotes | Pendiente | Preparar páginas de axial/panorámica/secciones y verificar numeración, escala y disposición. |
| Impresión DICOM | Pendiente | Integración con un servicio de impresión compatible y pruebas de interoperabilidad. |
| Exportación STL | Pendiente | Generar una malla, limpiar/suavizar sin cambios geométricos injustificados y exportar en unidades documentadas. |
| Paquetes USB/CD/DVD | Pendiente | Crear un paquete portable con datos y visor apropiado; separar exportación de archivos de grabación física del medio. |

## 7. Datos, proyectos y archivos

Esta sección combina referencias de base local/host remoto/PACS con límites comprobados del lector actual y archivos observados en el ejemplo. No afirma que Xelis soporte todas las variantes DICOM enumeradas aquí; son trabajos necesarios para ampliar la compatibilidad de DentalViewer.

| Función | Estado | Trabajo pendiente en DentalViewer |
| --- | --- | --- |
| Proyectos XPV | Parcial | Se identificó el XPV del ejemplo como índice de archivos. La geometría se recupera del DICOM de proyecto. Falta edición/escritura del índice y compatibilidad con otras versiones. |
| DICOM de proyecto de Xelis | Parcial | Se leen datos privados MEVISYS y su ZIP con zlib nativo, independientemente del JPEG de presentación; se importan arco y canales. Falta recuperar máscaras, anotaciones, implantes, propiedades y ajustes completos; soportar más versiones. |
| Bibliotecas/presets del ejemplo | Pendiente | Evaluar `.mdb`, `.pmf`, `.lpf`, `.lcp`, `.lwp` y otros archivos antes de atribuirles compatibilidad. |
| DICOM comprimido | Pendiente | Integrar codecs y verificar sintaxis de transferencia con archivos de referencia. El lector actual acepta únicamente Little Endian sin compresión. |
| CT multiframe y geometrías adicionales | Pendiente | Leer geometría por frame y soportar orientación oblicua, ejes invertidos y remuestreo de espaciados no uniformes. |
| Otros tipos de imagen | Pendiente | Ampliar las clases y formatos; definir claramente cuáles pueden reconstruirse como volumen. |
| DICOMDIR y paquetes de intercambio | Pendiente | Resolver rutas y referencias sin depender de extensiones o nombres de archivo. |
| Base local de estudios/pacientes | Pendiente | Catálogo persistente, búsqueda y gestión de casos. Actualmente se abren carpetas y se recuerda la última. |
| Host remoto / PACS | Pendiente | Definir protocolos, configuración e interoperabilidad con un servidor concreto. |
| Multiusuario | Pendiente | Gestión de usuarios, acceso a los estudios y coordinación de modificaciones. |
| Guardado de planificación propia | Parcial | `.dentalplan.json` guarda implantes y canales. Falta incluir mediciones, curvas, vistas, notas, historial y migraciones de formato. |
| Continuidad del trabajo | Pendiente | Autoguardado o aviso al salir/cambiar serie, recuperación y deshacer/rehacer. Hoy debe guardarse el plan explícitamente. |

## 8. Paridad de producto y validación

Estos son requisitos de madurez de nuestra aplicación, además de las herramientas visibles; no se presentan como funciones específicas publicadas de Xelis.

- Comparar resultados en varios estudios, fabricantes, campos de visión y artefactos.
- Verificar distancias, orientación, escala, interpolación y registro de anotaciones frente a referencias independientes.
- Ampliar las pruebas de interacción, persistencia, cambios de serie, errores y consumo de memoria.
- Revisar el flujo con usuarios que conocen Xelis y acordar controles/atajos familiares.
- Incorporar ayuda, documentación de limitaciones y manejo de errores recuperables.
- Preparar distribución firmada/notarizada, actualizaciones y compatibilidad de macOS/arquitecturas declaradas.
- Definir el uso previsto y completar la validación profesional/regulatoria que corresponda antes de ofrecer uso diagnóstico o planificación quirúrgica.

## Orden de trabajo

1. **Prioridad elegida por el usuario:** completar la planificación manual de implantes y canales, su edición y persistencia.
2. Integrar en la interfaz curva de arcada, panorámica y cortes dentales; usarlos para revisar la planificación.
3. Ampliar formatos DICOM y estudiar proyectos/bibliotecas originales con muestras verificables.
4. Incorporar mediciones, informes, STL y flujos de impresión/exportación.
5. Ampliar importación verificable de datos originales y módulos de análisis solicitados. No incorporar estimaciones de canal ni modelos de IA.
6. Validar la experiencia, interoperabilidad y precisión según el uso previsto.

## Limitaciones técnicas y dependencias

**Implementación local viable:** las vistas y herramientas manuales pueden construirse a partir del volumen y su geometría. El esfuerzo está en la precisión, interacción, persistencia y pruebas; macOS no impide desarrollarlas.

**Compatibilidad propietaria incierta:** el ejemplo contiene proyectos y bibliotecas propios de Xelis. Se verificó la estructura necesaria para recuperar el arco y los canales del ejemplo. Aún no puede prometerse importar todas sus anotaciones, modelos y ajustes, ni otras versiones. Puede ser necesaria documentación del fabricante o una exportación compatible.

**Automatización y uso clínico:** añadir un botón automático no demuestra un resultado fiable. Se necesitan algoritmos, datos y evaluación adecuados. El prototipo actual no establece equivalencia clínica con Xelis.

Detalles de interacción, algoritmo y límites del canal: [CANAL-MANDIBULAR.md](CANAL-MANDIBULAR.md).
