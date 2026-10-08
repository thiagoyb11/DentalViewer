# Auditoría de escala panorámica — DentalViewer

## Referencias y unidades

La regla inferior muestra **recorrido del arco en milímetros**. Es distinto de la numeración de cortes transversales de Xelis, que depende del paso y del rango de secciones. El [manual de Xelis Dental, página 50](https://esdent.pl/images/instrukcje/Infinitt-Xelis-Dental-Instrukcja-Obslugi.pdf#page=50) describe las líneas inferiores como referencias de cortes transversales. No corresponde convertir su numeración directamente a milímetros ni usarla como factor de escala.

## Comprobación de geometría

El auditor independiente [tools/audit_panoramic_scale.py](tools/audit_panoramic_scale.py) lee con `struct` un payload Xelis previamente extraído. Compara la longitud de la polilínea densa con la longitud y distancias de los marcos guardados, y calcula irregularidad de columnas y normas de los ejes. No usa el código Swift de geometría ni modifica el estudio. El payload y la salida contienen información privada y deben conservarse fuera del repositorio.

```sh
python3 tools/audit_panoramic_scale.py /ruta/privada/project-payload.bin
bash scripts/test.sh
# Comprobaciones adicionales sobre un estudio Xelis compatible local:
bash scripts/test.sh /ruta/al/estudio-privado
```

Las pruebas sintéticas verifican distancias conocidas, columnas irregulares, bordes de píxel, coordenadas de medición tras redimensionar y superficies desplazadas con ejes inclinados. La comprobación opcional de un estudio verifica importación y correspondencia geométrica sin incorporar valores anatómicos del paciente al código.

## Protocolo de verificación técnica

[Tests/TechnicalValidation.swift](Tests/TechnicalValidation.swift) genera seis series DICOM de 31 × 29 × 25 vóxeles con un campo de intensidad definido matemáticamente. Combina píxeles de 8 y 16 bits, valores con y sin signo, 12 bits almacenados, VR explícito e implícito, MONOCHROME1/2, pendientes positivas y negativas, orígenes desplazados y tres espaciados anisotrópicos.

Se comprueban todos los vóxeles y todos los píxeles de cada corte axial, coronal y sagital contra ese campo y la función LINEAR de [DICOM PS3.3 C.11.2](https://dicom.nema.org/medical/dicom/current/output/chtml/part03/sect_C.11.2.html). También se verifican muestreo trilineal, distancias de 3–4–5 mm con zoom, desplazamiento y distintos tamaños, secciones inclinadas a 0°, 25° y 60°, los manejadores de interacción transversal y longitudes analíticas de arcos circulares desplazados. Se rechazan metadatos no finitos, geometría incompatible y longitudes de píxeles incorrectas.

[tools/validate_study.py](tools/validate_study.py) lee directamente los DICOM y el proyecto Xelis con la biblioteca estándar de Python. Compara esa decodificación independiente con una referencia exportada por las pruebas Swift: dimensiones, origen, espaciado, referencias SOP, hashes SHA-256 de todos los píxeles almacenados después de enmascarar los bits sin uso, 80 intensidades reescaladas y cada muestra, control, marco y eje del arco y los canales. Verifica la CRC del ZIP y confirma que los archivos originales no cambiaron durante la auditoría. El lector de referencia se limita a CT monocromático axial little endian sin compresión y al esquema Xelis compatible descrito en el README.

```sh
bash scripts/test.sh
bash scripts/test.sh "/ruta/al/estudio-privado"
python3 tools/validate_study.py "/ruta/al/estudio-privado"
```

La segunda ejecución genera `output/technical-validation-private-reference.json`; contiene identificadores y coordenadas originales y debe permanecer local. Los resúmenes se guardan en `output/technical-validation-synthetic.json` y `output/technical-validation-study.json`. La opción `--screen-reference /ruta/al/registro-local.json` permite revisar observaciones de pantalla previas; ese registro no se distribuye.

## Resultados del 8 de octubre de 2026

La suite con el estudio local disponible pasó **846 comprobaciones**. Los resultados corresponden a esta ejecución y al alcance siguiente:

| Comprobación | Resultado |
| --- | --- |
| Vóxeles sintéticos conocidos | 134 850; diferencia de intensidad máxima 0. |
| Píxeles MPR sintéticos | 404 550; diferencia máxima 1 nivel de gris sobre 255. |
| Muestreo del campo continuo | 240 posiciones; diferencia de intensidad máxima 0. |
| Mediciones conocidas | 125; error numérico máximo inferior a 10⁻⁹ mm. |
| Escala visual transversal | Igualdad de escala horizontal y vertical dentro de 10⁻¹⁰, en mosaico y sección ampliada. |
| Lectura independiente del estudio | 316 cortes y 156 614 656 vóxeles; todos los hashes de píxeles coinciden. |
| Geometría original de Xelis | 2 151 posiciones, junto con todos los ejes y distancias de marcos; diferencias máximas 0. |
| Longitud del arco calculada independientemente | Diferencia inferior a 10⁻⁸ mm. |
| Controles negativos del auditor | Rechazó un hash incorrecto y una posición desplazada 1 mm en copias de la referencia. |
| Interfaz nativa | Renderizado Metal visible; una medición transversal conservó su valor al ampliar el mosaico, ampliar una sección y cambiar el tamaño de ventana. |

Metal no estuvo disponible para compilar el shader desde el entorno CLI de esta ejecución; la comprobación del renderizado se realizó abriendo la aplicación compilada. Se recuperó el control de Xelis en VMware y se consultaron sus vistas panorámica y transversal. Las tres comparaciones de mediciones de pantalla registradas anteriormente tuvieron una diferencia máxima aproximada de 0.321 mm respecto del cálculo independiente; el umbral de 0.5 mm de ese registro es un criterio de regresión de pantalla, no una tolerancia clínica ni una prueba de equivalencia tridimensional.

## Defectos encontrados y corregidos

1. **Relleno de Pixel Data de 8 bits:** una imagen válida con cantidad impar de píxeles se rechazaba porque el lector exigía exactamente la cantidad de bytes de los vóxeles. Se admite el byte final necesario para una longitud par y se excluye de la decodificación, conforme a [DICOM PS3.5, capítulo 8](https://dicom.nema.org/medical/dicom/current/output/chtml/part05/chapter_8.html). Las pruebas cubren relleno con valor no nulo, ausencia de relleno y bytes excedentes.
2. **Proporción visual transversal:** el ancho físico de la imagen omitía medio píxel en cada borde mientras su altura sí los incluía. Se corrigió el rectángulo de presentación para que un milímetro tenga la misma escala en ambos ejes. El cálculo de longitud en el plano ya utilizaba las coordenadas físicas; la corrección afecta la proporción visual.

## Interfaz y mediciones

- La regla lleva la unidad «Recorrido del arco · mm», con marcas cada milímetro y números cada diez.
- La barra vertical de 10 mm usa el espaciado DICOM.
- El rectángulo físico incluye medio píxel a cada extremo, también en el eje horizontal.
- Las medidas horizontales usan distancias acumuladas de las columnas; las verticales usan separación de cortes. Las diagonales combinan ambas componentes en la panorámica desplegada, sin representar una cuerda tridimensional.
- Cambiar profundidad recalcula la superficie y su longitud e invalida las medidas anteriores.
- La regla invierte la distancia acumulada para ubicar las marcas de columnas irregulares. El bitmap conserva las columnas originales: no se presenta como un remuestreo horizontal físicamente uniforme.

## Alcance y privacidad

Las comparaciones de pantalla con otro visor incluyen incertidumbre por selección de píxeles, redondeo y ajustes de presentación. No demuestran equivalencia exacta de extremos tridimensionales ni precisión clínica. La auditoría no constituye validación diagnóstica o quirúrgica.

La igualdad con los archivos originales comprueba conservación de datos y trazados guardados, no la corrección anatómica de esos trazados. Los errores mínimos de las series matemáticas describen precisión numérica sobre datos ideales, no exactitud de adquisición CBCT. Para ampliar la evidencia hacen falta estudios de otros equipos, comparaciones con los mismos extremos físicos en ambos visores, un fantoma con distancias conocidas y revisión de tareas clínicas por odontólogos.

Los informes del estudio de prueba, referencias de medición, coordenadas anatómicas, identificadores y capturas se conservan únicamente en local y no se publican. La documentación pública describe el método y sus límites sin reproducir datos del paciente.
