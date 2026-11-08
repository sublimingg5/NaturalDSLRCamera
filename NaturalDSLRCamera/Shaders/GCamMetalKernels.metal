#include <metal_stdlib>
using namespace metal;

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

// MARK: - 2. Hierarchical Block Matching (Estimación de Movimiento Local de Bloques)
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
    
    // Leer estimador del nivel piramidal anterior escalado x2
    float2 baseVector = float2(0.0f, 0.0f);
    if (prevLevelVectors.get_width() > 1) {
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
    
    // Búsqueda espacial alrededor del vector previo
    for (int dy = -searchRadius; dy <= searchRadius; dy++) {
        for (int dx = -searchRadius; dx <= searchRadius; dx++) {
            float2 candidate = baseVector + float2(float(dx), float(dy));
            float currentSAD = 0.0f;
            int samples = 0;
            
            // Submuestreo de paso 2 dentro del bloque para acelerar en GPU
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
    
    outVectors.write(float4(bestOffset.x, bestOffset.y, minSAD, 1.0f), gid);
}

// MARK: - 3. Fusión Robusta Temporal con Modelo de Ruido del Sensor (Anti-Ghosting)
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
    
    // Obtener vector de movimiento correspondiente al bloque
    uint2 mvCoord = min(gid / uint(motionBlockSize), uint2(motionVectors.get_width() - 1, motionVectors.get_height() - 1));
    float2 motion = motionVectors.read(mvCoord).xy;
    
    int2 targetCoord = int2(gid) + int2(round(motion));
    float yk = y0;
    bool inBounds = (targetCoord.x >= 0 && targetCoord.x < int(targetLuma.get_width()) &&
                     targetCoord.y >= 0 && targetCoord.y < int(targetLuma.get_height()));
    if (inBounds) {
        yk = targetLuma.read(uint2(targetCoord)).r;
    }
    
    // Modelo físico de ruido del sensor: σ²(y) = σ_read² + σ_shot² · y
    float variance = (readNoise * readNoise) + (shotNoise * max(y0, 0.002f));
    float delta = abs(yk - y0);
    
    // Ponderación de robustez bilateral temporal (si delta excede 3.5σ, el peso tiende a 0)
    float weight = inBounds ? exp(-(delta * delta) / (2.0f * 12.25f * variance)) : 0.0f;
    weight = clamp(weight, 0.0f, 1.0f);
    
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
    
    float sumY = accumLuma.read(gid).r;
    float sumW = max(weightMap.read(gid).r, 0.0001f);
    float yNorm = sumY / sumW;
    
    // Microcontraste óptico de texturas sin halos (Canon Fine Detail acutance)
    // Se calcula laplaciano local simple en luminancia
    uint w = accumLuma.get_width();
    uint h = accumLuma.get_height();
    
    float yUp = accumLuma.read(uint2(gid.x, max(int(gid.y) - 1, 0))).r / sumW;
    float yDown = accumLuma.read(uint2(gid.x, min(gid.y + 1, h - 1))).r / sumW;
    float yLeft = accumLuma.read(uint2(max(int(gid.x) - 1, 0), gid.y)).r / sumW;
    float yRight = accumLuma.read(uint2(min(gid.x + 1, w - 1), gid.y)).r / sumW;
    
    float laplacian = (yNorm * 4.0f) - (yUp + yDown + yLeft + yRight);
    
    // Atenuación de acutancia en áreas con bajo peso (sujetos en movimiento)
    float confidence = clamp(sumW / 8.0f, 0.2f, 1.0f);
    float sharpenedY = yNorm + (laplacian * acutanceStrength * confidence * 0.15f);
    sharpenedY = clamp(sharpenedY, 0.0f, 1.0f);
    
    // Curva Highlight Tone Priority (HTP) de Canon:
    // Aplica la ganancia de exposición recuperada pero con hombro suave de roll-off
    float linY = sharpenedY * exposureGain;
    float shoulderK = 0.80f;
    float finalY = linY;
    
    if (linY > shoulderK) {
        float overshoot = linY - shoulderK;
        float maxHeadroom = 1.0f - shoulderK;
        finalY = shoulderK + maxHeadroom * (overshoot / (overshoot + shoulderCompression));
    }
    finalY = clamp(finalY, 0.0f, 1.0f);
    
    // Leer crominancia de hardware CbCr (resolución media 4:2:0)
    uint2 chromaCoord = min(gid / 2, uint2(chromaTexture.get_width() - 1, chromaTexture.get_height() - 1));
    float2 cbcr = chromaTexture.read(chromaCoord).rg;
    float cb = cbcr.x - 0.5f;
    float cr = cbcr.y - 0.5f;
    
    // Matriz de conversión HDTV BT.709 a RGB (preserva neutralidad cromática)
    float r = finalY + (1.57480f * cr);
    float g = finalY - (0.18732f * cb) - (0.46812f * cr);
    float b = finalY + (1.85560f * cb);
    
    outRGB.write(float4(clamp(float3(r, g, b), 0.0f, 1.0f), 1.0f), gid);
}
