# DentalViewer para macOS

Visor nativo de estudios CT/CBCT DICOM y de trazados originales guardados en el proyecto Xelis del ejemplo. Usa AppKit, SwiftUI, Metal y zlib del sistema. **No usa Docker, modelos de IA ni búsqueda de recorridos por intensidad.** Los archivos originales se leen sin modificarse.

## Abrir el estudio

Abrí `output/DentalViewer.app` y seleccioná la carpeta completa o `Data`. Se recuerda la última carpeta abierta.

La ventana tiene un tamaño mínimo de contenido de **1080 × 720 puntos**. Los paneles sin espacio dibujable durante un cambio de tamaño omiten el dibujo hasta recuperar dimensiones válidas.

- **Dental**: nueve secciones transversales y panorámica a la izquierda, axial y 3D a la derecha, histograma y contraste abajo.
- **Ampliar panel**: las flechas en el encabezado amplían axial, panorámica, 3D, MPR o revisión del canal dentro del área de imágenes. El mismo botón restaura la distribución, conservando encuadre y mediciones. Cada sección del mosaico también tiene un botón en su esquina para verla individualmente. La barra lateral y los controles de la aplicación permanecen disponibles.
- La curva dental y los dos canales se recuperan del DICOM de proyecto Xelis. Los canales aparecen en **verde** en 3D, MPR, transversales y panorámica. La panorámica muestra su proyección sobre el arco.
- **Canal mandibular**: elegí un canal original: el selector centra sus cortes inmediatamente y cambia la revisión activa. **Recorrer canal original** abre cortes perpendiculares y longitudinales del trazado elegido. Panorámica y 3D muestran ambos canales juntos. **Mostrar canales originales** controla su visibilidad.
- Las coordenadas del proyecto original se conservan sin suavizarlas ni estimar posiciones. El grosor verde es un estilo visual y no una medición del diámetro anatómico.
- Clic, rueda o deslizador panorámico recorre el arco; paso transversal y campo son configurables. **Profundidad** desplaza la superficie panorámica de −10 a +10 mm respecto del arco original (deslizador, botones de 0.1 mm o ⇧ + rueda). La axial muestra en cian la superficie y los límites del espesor. **Espesor** controla la capa promediada de 0 a 10 mm. Mientras se calcula una nueva profundidad se conserva el cuadro anterior, con su escala y proyección del canal, y se reemplaza completo al terminar; las solicitudes superadas se cancelan. El botón de restablecer profundidad vuelve a 0 mm; el arco y los canales originales permanecen intactos.
- **MPR**: planos axial, coronal y sagital sincronizados. Clic mueve la referencia; rueda avanza cortes; ⌘ + rueda o pellizcar cambia zoom; ⌥ + arrastrar desplaza la imagen.
- En 3D, arrastrar rota siguiendo el mouse; rueda cambia zoom y doble clic restablece. La vista se dibuja cuando hay cambios.
- **Contraste**: centro/ventana, presets y arrastre en axial, MPR, panorámica y transversales. Arrastre vertical cambia Centro; horizontal cambia Ventana. **Medir**: seleccioná la herramienta y arrastrá entre dos puntos dentro de la imagen. Funciona también en las secciones transversales del mosaico y en paneles ampliados. Se muestran la línea amarilla y su longitud en mm. En transversales se usa la distancia física entre extremos del plano guardado, incluidos sus ejes inclinados; en panorámica, el ancho mide recorrido sobre el arco desplegado y la altura usa el espaciado del CT. Las medidas se mantienen durante la sesión y pueden borrarse en **MEDICIONES**; redefinir la curva las invalida y cambiar profundidad borra las panorámicas. La escala horizontal se recalcula para la superficie desplazada. La regla inferior dice **Recorrido del arco · mm** y hay una barra vertical de **10 mm**. Es distancia sobre el arco, diferente de la numeración de secciones de Xelis. Ver [AUDITORIA-ESCALA-PANORAMICA.md](AUDITORIA-ESCALA-PANORAMICA.md). **Captura**: PNG de la ventana.
- **Implante** y **Canal mandibular**: reciben clic y arrastre en axial, MPR, panorámica y transversales. En panorámica se ubican sobre la superficie correspondiente a la profundidad mostrada; en transversales, sobre el plano de sección. El canal manual admite marcar puntos, seleccionarlos/arrastrarlos e insertar sobre un segmento según la acción elegida. **Curva dental** amplía axial para definir un arco manual en estudios sin proyecto compatible; permanece deshabilitada al usar la curva original guardada de Xelis.
- La planificación manual conserva implantes genéricos y canales editables, deshacer/rehacer y revisión de recorrido. **Guardar plan/Cargar plan** usa `.dentalplan.json`; guardá antes de cerrar. Los trazados originales de Xelis se recuperan del proyecto al abrir y no forman parte de ese archivo propio.

## Compatibilidad

Los CT compatibles son monocromáticos, axiales LPS, uniformemente espaciados, de 8 o 16 bits, sin compresión. Se verifican geometría, intensidades y cortes faltantes/duplicados.

Un estudio Xelis compatible incluye un índice XPV y un DICOM de proyecto que puede contener una imagen de presentación JPEG Lossless y datos privados. La app lee los datos privados sin necesitar decodificar la imagen JPEG. Importa la curva dental y la colección de canales de **Lucion/Xelis 1.0.6.4 BN2(P)**, metadatos de snapshot `30000001` y payload `30000017`. Se verifica CRC ZIP, referencias a todos los SOP Instance UID originales y límites físicos. Otras versiones o datos ambiguos se informan sin inventar geometría.

Se conservan las muestras, los puntos de control y los marcos originales del arco y de los canales, sin publicar geometría de pacientes. Aún no se importan todos los ajustes, anotaciones, máscaras, implantes ni bibliotecas propietarios. Más detalles en [CANAL-MANDIBULAR.md](CANAL-MANDIBULAR.md) y [FUNCIONALIDADES-PENDIENTES-XELIS.md](FUNCIONALIDADES-PENDIENTES-XELIS.md).

El 3D usa una copia reducida del CT de hasta 320 muestras por eje y una superficie de umbral; los cortes usan las imágenes originales. Los trazados se superponen al hueso para mantenerlos visibles. El límite de 256 elementos se aplica a la planificación manual, no a los canales originales importados.

Prototipo de visualización sin validación diagnóstica o quirúrgica. No es un producto de INFINITT o Trident.

## Compilar y verificar

Requiere macOS 13+, herramientas de línea de comandos de Xcode y GPU compatible con Metal. No necesita instalar motores externos.

```sh
bash scripts/build.sh
bash scripts/test.sh
# Opcional: estudio privado compatible, conservado fuera del repositorio.
bash scripts/test.sh "/ruta/al/estudio-privado"
```

Las pruebas cubren DICOM, geometría, rotación, planificación manual y recuperación de coordenadas originales. Rechazan proyectos truncados, CRC incorrecto, versiones desconocidas y referencias a otro estudio/serie. Metal se verifica en la app cuando la GPU no está disponible en el entorno CLI.

## Privacidad del repositorio

El repositorio contiene código, pruebas sintéticas y documentación técnica. No incluye estudios de pacientes, nombres, identificadores DICOM reales, coordenadas anatómicas de referencia, capturas, planificación ni resultados privados de auditoría. Los estudios se abren desde una carpeta local y se conservan fuera del control de versiones. `output/` y las referencias privadas de medición están excluidos mediante `.gitignore`.
