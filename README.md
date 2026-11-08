# Natural DSLR Camera (iPhone 11 Zero-ISP Pipeline)

Aplicación de cámara en Swift/SwiftUI diseñada específicamente para evitar el procesado computacional del iPhone 11 (**Smart HDR 2**, **Deep Fusion**, reducción de ruido espacial/temporal con efecto acuarela y *unsharp mask* con halos blancos).

## Cómo funciona internamente

1. **Captura física Bayer RAW de 14 bits (`AVCapturePhotoOutput`):**
   - Selecciona directamente el sensor físico trasero **26mm ƒ/1.8 Wide (Sony IMX503 de 12 MP con OIS)** evitando las cámaras virtuales.
   - Solicita el formato Bayer crudo (`kCVPixelFormatType_14Bayer_RGGB`) con `photoQualityPrioritization = .speed` y estabilización computacional desactivada, forzando **una única exposición física del sensor**.
2. **Revelado propio en GPU (`CIRAWFilter` + Metal):**
   - Procesa los bytes `.dng` en memoria con `luminanceNoiseReductionAmount = 0.0` (conserva el 100% del grano monocromático orgánico del sensor), `sharpnessAmount = 0.0` (cero halos), `localToneMapAmount = 0.0` (contraste óptico real) y `colorNoiseReductionAmount = 0.20` (elimina el moteado RGB del mosaico Bayer sin tocar el grano).
   - Aplica una curva tonal en S (*Filmic Roll-Off*) que protege las altas luces y exporta directamente a **JPEG (95%) o HEIC en espacio Display P3**.

## Controles incluidos

- **Modo Point & Shoot (`P&S AUTO`) y botón `MANUAL`:**
  - En **P&S AUTO**: Enfoque al toque, subexposición protectora de altas luces (`-0.4 EV`), deslizador rápido de compensación EV (`-2.0` a `+2.0`) y perfiles ópticos (*Natural DSLR*, *Filmic Soft*, *B&W Grain*).
  - En **MANUAL**: Diales dedicados para **Velocidad de Obturación (`1/4s` a `1/4000s`)**, **ISO**, **Enfoque Manual (`MF`/`AF`)** y **Balance de Blancos en Kelvin (`2800K`–`8500K`)**.
- **Botón `JPEG/HEIC` vs `RAW`:** Alterna al instante entre guardar solo la foto revelada natural o incluir el archivo `.dng` crudo.
- **Botón de Settings (`⚙️`):** Permite activar/desactivar la **corrección óptica de lente** (activada por defecto; al desactivarla conserva el viñeteo óptico natural del lente 26mm ƒ/1.8), elegir entre JPEG o HEIC y calibrar el grano/curva.

---

## Cómo compilar el `.ipa` desde Windows (Gratis con GitHub Actions) e instalarlo en tu iPhone 11

1. **Subir este proyecto a un repositorio de GitHub:**
   ```powershell
   cd c:\Users\Facu\Documents\NaturalDSLRCamera
   git init
   git add .
   git commit -m "Initial commit: Natural DSLR Camera for iPhone 11"
   git branch -M main
   git remote add origin https://github.com/TU_USUARIO/NaturalDSLRCamera.git
   git push -u origin main
   ```
2. **Descargar el `.ipa` compilado:**
   - Entrá a la pestaña **Actions** de tu repositorio en GitHub.
   - Verás el workflow **Build iOS IPA (Unsigned for Sideloading)** corriendo en un runner macOS de GitHub.
   - Cuando termine (tarda ~2 minutos), bajá el artefacto **`NaturalDSLRCamera-IPA`** y descomprimí el archivo `NaturalDSLRCamera.ipa`.
3. **Sideloadear en el iPhone 11:**
   - Abrí **SideStore**, **AltStore** o **Sideloadly** y seleccioná `NaturalDSLRCamera.ipa`.
   - Ingresá tu Apple ID gratuito para que lo firme con tu certificado personal (7 días, renovable automáticamente por Wi-Fi con SideStore/AltStore).
   - En el iPhone 11, asegurate de tener activado **Ajustes → Privacidad y seguridad → Modo Desarrollador**.
