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

## Interfaz y mediciones

- La regla lleva la unidad «Recorrido del arco · mm», con marcas cada milímetro y números cada diez.
- La barra vertical de 10 mm usa el espaciado DICOM.
- El rectángulo físico incluye medio píxel a cada extremo, también en el eje horizontal.
- Las medidas horizontales usan distancias acumuladas de las columnas; las verticales usan separación de cortes. Las diagonales combinan ambas componentes en la panorámica desplegada, sin representar una cuerda tridimensional.
- Cambiar profundidad recalcula la superficie y su longitud e invalida las medidas anteriores.
- La regla invierte la distancia acumulada para ubicar las marcas de columnas irregulares. El bitmap conserva las columnas originales: no se presenta como un remuestreo horizontal físicamente uniforme.

## Alcance y privacidad

Las comparaciones de pantalla con otro visor incluyen incertidumbre por selección de píxeles, redondeo y ajustes de presentación. No demuestran equivalencia exacta de extremos tridimensionales ni precisión clínica. La auditoría no constituye validación diagnóstica o quirúrgica.

Los informes del estudio de prueba, referencias de medición, coordenadas anatómicas, identificadores y capturas se conservan únicamente en local y no se publican. La documentación pública describe el método y sus límites sin reproducir datos del paciente.
