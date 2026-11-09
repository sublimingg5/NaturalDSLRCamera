#include <metal_stdlib>
using namespace metal;

// MARK: - 0. Inicialización Limpia del Acumulador (Cuadro Base)
kernel void gcam_initialize_accumulator(
    texture2d<float, access::read> refLuma          [[texture(0)]],
    texture2d<float, access::write> outAccumLuma    [[texture(1)]],
    texture2d<float, access::write> outWeightMap    [[texture(2)]],
    uint2 gid                                       [[thread_position_in_grid]])
{
    if (gid.x >= outAccumLuma.get_width() || gid.y >= outAccumLuma.get_height()) {
        return;
    }
    
    float y0 = refLuma.read(gid).r;
    outAccumLuma.write(float4(y0, 0.0f, 0.0f, 1.0f), gid);
    outWeightMap.write(float4(1.0f, 0.0f, 0.0f, 1.0f), gid);
}

// MARK: - 1. Reducción Piramidal Gaussiana (2x2 Box / Binomial)
kernel void gcam_pyramid_downsample(
    texture2d<float, access::read> inTexture   [[texture(0)]],
    texture2d<float, access::write> outTexture [[texture(1)]],
    uint2 gid                                  [[thread_position_in_grid]])
{
    if (gid.x >= outTexture.get_width() || gid.y >= outTexture.get_height()) {
        return;
    }
    
    uint2 src = gid * 2;
    uint w = inTexture.get_width();
    uint h = inTexture.get_height();
    
    float p00 = inTexture.read(src).r;
    float p10 = (src.x + 1 < w) ? inTexture.read(src + uint2(1, 0)).r : p00;
    float p01 = (src.y + 1 < h) ? inTexture.read(src + uint2(0, 1)).r : p00;
    float p11 = (src.x + 1 < w && src.y + 1 < h) ? inTexture.read(src + uint2(1, 1)).r : p00;
    
    float avg = (p00 + p10 + p01 + p11) * 0.25f;
    outTexture.write(float4(avg, 0.0f, 0.0f, 1.0f), gid);
}

// MARK: - 2. Hierarchical Block Matching (Estimación de Movimiento Jerárquica Coarse-to-Fine)
kernel void gcam_block_matching(
    texture2d<float, access::read> refTexture        [[texture(0)]],
    texture2d<float, access::read> targetTexture     [[texture(1)]],
    texture2d<float, access::read> prevLevelVectors  [[texture(2)]],
    texture2d<float, access::write> outVectors       [[texture(3)]],
    constant int &searchRadius                       [[buffer(0)]],
    constant int &blockSize                          [[buffer(1)]],
    uint2 gid                                        [[thread_position_in_grid]])
{
    if (gid.x >= outVectors.get_width() || gid.y >= outVectors.get_height()) {
        return;
    }
    
    // Si existe vector del nivel piramidal anterior (más grueso), escalarlo x2 como estimación inicial
    float2 baseVector = float2(0.0f, 0.0f);
    if (prevLevelVectors.get_width() > 1 && prevLevelVectors.get_height() > 1) {
        uint2 prevCoord = min(gid / 2, uint2(prevLevelVectors.get_width() - 1, prevLevelVectors.get_height() - 1));
        baseVector = prevLevelVectors.read(prevCoord).xy * 2.0f;
    }
    
    int2 blockOrigin = int2(gid) * blockSize;
    float minSAD = 1e9f;
    float2 bestOffset = baseVector;
    
    int refW = int(refTexture.get_width());
    int refH = int(refTexture.get_height());
    int tgtW = int(targetTexture.get_width());
    int tgtH = int(targetTexture.get_height());
    
    // Búsqueda espacial refinada alrededor del vector previo
    for (int dy = -searchRadius; dy <= searchRadius; dy++) {
        for (int dx = -searchRadius; dx <= searchRadius; dx++) {
            float2 candidate = baseVector + float2(float(dx), float(dy));
            float currentSAD = 0.0f;
            int samples = 0;
            
            // Submuestreo paso 2 para eficiencia máxima en GPU
            for (int by = 0; by < blockSize; by += 2) {
                for (int bx = 0; bx < blockSize; bx += 2) {
                    int rx = blockOrigin.x + bx;
                    int ry = blockOrigin.y + by;
                    int tx = rx + int(round(candidate.x));
                    int ty = ry + int(round(candidate.y));
                    
                    if (rx < refW && ry < refH && tx >= 0 && tx < tgtW && ty >= 0 && ty < tgtH) {
                        float rVal = refTexture.read(uint2(rx, ry)).r;
                        float tVal = targetTexture.read(uint2(tx, ty)).r;
                        currentSAD += abs(rVal - tVal);
                        samples++;
                    }
                }
            }
            
            if (samples > 0) {
                currentSAD /= float(samples);
                if (currentSAD < minSAD) {
                    minSAD = currentSAD;
                    bestOffset = candidate;
                }
            }
        }
    }
    
    // Guardar: xy = vector de movimiento, z = minSAD (métrica de fiabilidad), w = 1.0
    outVectors.write(float4(bestOffset.x, bestOffset.y, minSAD, 1.0f), gid);
}

// MARK: - 3. Fusión Robusta Temporal con Modelo de Ruido Estricto (Anti-Ghosting Tipo GCam)
kernel void gcam_robust_accumulate(
    texture2d<float, access::read> refLuma          [[texture(0)]],
    texture2d<float, access::read> targetLuma       [[texture(1)]],
    texture2d<float, access::read> motionVectors    [[texture(2)]],
    texture2d<float, access::read> prevAccumLuma    [[texture(3)]],
    texture2d<float, access::read> prevWeightMap    [[texture(4)]],
    texture2d<float, access::write> outAccumLuma    [[texture(5)]],
    texture2d<float, access::write> outWeightMap    [[texture(6)]],
    constant float &readNoise                       [[buffer(0)]],
    constant float &shotNoise                       [[buffer(1)]],
    constant int &motionBlockSize                   [[buffer(2)]],
    uint2 gid                                       [[thread_position_in_grid]])
{
    if (gid.x >= refLuma.get_width() || gid.y >= refLuma.get_height()) {
        return;
    }
    
    float y0 = refLuma.read(gid).r;
    
    // Obtener vector de movimiento y métrica SAD del bloque
    uint2 mvCoord = min(gid / uint(motionBlockSize), uint2(motionVectors.get_width() - 1, motionVectors.get_height() - 1));
    float4 mvData = motionVectors.read(mvCoord);
    float2 motion = mvData.xy;
    float blockSAD = mvData.z;
    
    int2 targetCoord = int2(gid) + int2(round(motion));
    float yk = y0;
    bool inBounds = (targetCoord.x >= 0 && targetCoord.x < int(targetLuma.get_width()) &&
                     targetCoord.y >= 0 && targetCoord.y < int(targetLuma.get_height()));
    if (inBounds) {
        yk = targetLuma.read(uint2(targetCoord)).r;
    }
    
    // Desviación estándar de ruido Poisson-Gaussiana: σ(y) = √(σ_read² + σ_shot² · y)
    float noiseSigma = sqrt((readNoise * readNoise) + (shotNoise * shotNoise * max(y0, 0.001f)));
    float delta = abs(yk - y0);
    
    // Ponderación Tukey Biweight estricta tipo Google Camera Sabre:
    // A 3.0σ el peso cae limpiamente a 0.0 absoluto.
    float normalizedDiff = delta / max(noiseSigma, 0.006f);
    float weight = 0.0f;
    if (inBounds && normalizedDiff < 3.0f) {
        float factor = 1.0f - (normalizedDiff / 3.0f);
        weight = factor * factor;
    }
    
    // Penalización por discordancia de bloque: si el bloque sufrió movimiento de sujeto o desenfoque severo
    if (blockSAD > 0.05f) {
        float sadFactor = max(0.0f, 1.0f - (blockSAD - 0.05f) * 12.0f);
        weight *= sadFactor;
    }
    
    float curAccum = prevAccumLuma.read(gid).r;
    float curWeight = prevWeightMap.read(gid).r;
    
    outAccumLuma.write(float4(curAccum + (yk * weight), 0.0f, 0.0f, 1.0f), gid);
    outWeightMap.write(float4(curWeight + weight, 0.0f, 0.0f, 1.0f), gid);
}

// MARK: - 4. Mapeo Tonal Canon Highlight Tone Priority + Conversión Final YCbCr -> RGB
kernel void gcam_finalize_canon_tone(
    texture2d<float, access::read> accumLuma        [[texture(0)]],
    texture2d<float, access::read> weightMap        [[texture(1)]],
    texture2d<float, access::read> chromaTexture    [[texture(2)]],
    texture2d<float, access::write> outRGB          [[texture(3)]],
    constant float &exposureGain                    [[buffer(0)]],
    constant float &shoulderCompression             [[buffer(1)]],
    constant float &acutanceStrength                [[buffer(2)]],
    uint2 gid                                       [[thread_position_in_grid]])
{
    if (gid.x >= outRGB.get_width() || gid.y >= outRGB.get_height()) {
        return;
    }
    
    uint w = accumLuma.get_width();
    uint h = accumLuma.get_height();
    
    float sumW = max(weightMap.read(gid).r, 0.0001f);
    float yNorm = accumLuma.read(gid).r / sumW;
    
    // Microcontraste óptico Canon Fine Detail con normalización individual por píxel
    float wUp = max(weightMap.read(uint2(gid.x, max(int(gid.y) - 1, 0))).r, 0.0001f);
    float wDown = max(weightMap.read(uint2(gid.x, min(gid.y + 1, h - 1))).r, 0.0001f);
    float wLeft = max(weightMap.read(uint2(max(int(gid.x) - 1, 0), gid.y)).r, 0.0001f);
    float wRight = max(weightMap.read(uint2(min(gid.x + 1, w - 1), gid.y)).r, 0.0001f);
    
    float yUp = accumLuma.read(uint2(gid.x, max(int(gid.y) - 1, 0))).r / wUp;
    float yDown = accumLuma.read(uint2(gid.x, min(gid.y + 1, h - 1))).r / wDown;
    float yLeft = accumLuma.read(uint2(max(int(gid.x) - 1, 0), gid.y)).r / wLeft;
    float yRight = accumLuma.read(uint2(min(gid.x + 1, w - 1), gid.y)).r / wRight;
    
    float laplacian = (yNorm * 4.0f) - (yUp + yDown + yLeft + yRight);
    
    // Limitar acutancia proporcionalmente a la confianza temporal
    float confidence = clamp(sumW / 8.0f, 0.25f, 1.0f);
    float sharpenedY = yNorm + (laplacian * acutanceStrength * confidence * 0.15f);
    sharpenedY = clamp(sharpenedY, 0.0f, 1.0f);
    
    // Curva Highlight Tone Priority (HTP) de Canon:
    float linY = sharpenedY * exposureGain;
    float shoulderK = 0.80f;
    float finalY = linY;
    
    if (linY > shoulderK) {
        float overshoot = linY - shoulderK;
        float maxHeadroom = 1.0f - shoulderK;
        finalY = shoulderK + maxHeadroom * (overshoot / (overshoot + shoulderCompression));
    }
    finalY = clamp(finalY, 0.0f, 1.0f);
    
    // Leer crominancia CbCr calibrada por hardware
    uint2 chromaCoord = min(gid / 2, uint2(chromaTexture.get_width() - 1, chromaTexture.get_height() - 1));
    float2 cbcr = chromaTexture.read(chromaCoord).rg;
    float cb = cbcr.x - 0.5f;
    float cr = cbcr.y - 0.5f;
    
    // Matriz de conversión HDTV BT.709 a RGB
    float r = finalY + (1.57480f * cr);
    float g = finalY - (0.18732f * cb) - (0.46812f * cr);
    float b = finalY + (1.85560f * cb);
    
    outRGB.write(float4(clamp(float3(r, g, b), 0.0f, 1.0f), 1.0f), gid);
}
