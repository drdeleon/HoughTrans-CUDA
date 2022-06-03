/*
============================================================================
Author        : G. Barlas
Version       : 1.0
Last modified : December 2014
License       : Released under the GNU GPL 3.0
Description   :
To build use  : make
============================================================================
*/
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <cuda.h>
#include <string.h>
#include "pgm.h"


const int degreeInc = 2;
const int degreeBins = 180 / degreeInc;
const int rBins = 100;
const float radInc = degreeInc * M_PI / 180;



void CPU_HoughTran (unsigned char *pic, int w, int h, int **acc)
{
  float rMax = sqrt (1.0 * w * w + 1.0 * h * h) / 2;   //(w^2 + h^2)/2, radio max equivalente a centro -> esquina
  
  *acc = new int[rBins * degreeBins];                  //el acumulador, conteo depixeles encontrados, 90*180/degInc = 9000
  
  memset (*acc, 0, sizeof (int) * rBins * degreeBins); //init en ceros

  int xCent = w / 2;
  int yCent = h / 2;
  float rScale = 2 * rMax / rBins;


  for (int i = 0; i < w; i++)     //por cada pixel
    for (int j = 0; j < h; j++)
      {
        int idx = j * w + i;
        if (pic[idx] > 0)         //si pasa thresh, entonces lo marca
          {
            int xCoord = i - xCent;
            int yCoord = yCent - j;                       // y-coord has to be reversed

            float theta = 0;                              // actual angle
            for (int tIdx = 0; tIdx < degreeBins; tIdx++) //add 1 to all lines in that pixel
              {
                float r = xCoord * cos (theta) + yCoord * sin (theta);

                int rIdx = (r + rMax) / rScale;
                (*acc)[rIdx * degreeBins + tIdx]++;       //+1 para este radio r y este theta

                theta += radInc;
              }
          }
      }
}


//TODO Kernel memoria compartida
// __global__ void GPU_HoughTranShared(...)
// {
//   //TODO
// }


// declaración de variables en scope global
__constant__ float d_Cos[degreeBins];
__constant__ float d_Sin[degreeBins];

/*
*  params:
*    pic    -> arreglo con pixeles de la imagen
*    w      -> largo
*    h      -> alto
*    acc    -> store de calculos
*    rMax   -> distancia maxima
*    rScale -> escala de distancia
*/
__global__ void GPU_HoughTranConst(unsigned char *pic, int w, int h, int *acc, float rMax, float rScale)
{
  int gloID   = (blockIdx.x) * blockDim.x + threadIdx.x;

  if (gloID > w * h) return;      // in case of extra threads in block

  int xCent = w / 2;
  int yCent = h / 2;

  int xCoord = gloID % w - xCent;
  int yCoord = yCent - gloID / w;

  if (pic[gloID] > 0)
    {
      for (int tIdx = 0; tIdx < degreeBins; tIdx++)
        {
          float r = xCoord * d_Cos[tIdx] + yCoord * d_Sin[tIdx];
          int rIdx = (r + rMax) / rScale;

          //debemos usar atomic, pero que race condition hay si somos un thread por pixel? explique

          atomicAdd (acc + (rIdx * degreeBins + tIdx), 1);
        }
    }  
}

// GPU kernel. One thread per image pixel is spawned.
// The accummulator memory needs to be allocated by the host in global memory
__global__ void GPU_HoughTran (unsigned char *pic, int w, int h, int *acc, float rMax, float rScale, float *d_Cos, float *d_Sin)
{
  int gloID   = (blockIdx.x) * blockDim.x + threadIdx.x;
  
  if (gloID > w * h) return;      // in case of extra threads in block

  int xCent = w / 2;
  int yCent = h / 2;

  int xCoord = gloID % w - xCent;
  int yCoord = yCent - gloID / w;

  //TODO eventualmente usar memoria compartida para el acumulador

  if (pic[gloID] > 0)
    {
      for (int tIdx = 0; tIdx < degreeBins; tIdx++)
        {
          //TODO utilizar memoria constante para senos y cosenos
          //float r = xCoord * cos(tIdx) + yCoord * sin(tIdx); //probar con esto para ver diferencia en tiempo
          float r = xCoord * d_Cos[tIdx] + yCoord * d_Sin[tIdx];
          int rIdx = (r + rMax) / rScale;
          //debemos usar atomic, pero que race condition hay si somos un thread por pixel? explique
          atomicAdd (acc + (rIdx * degreeBins + tIdx), 1);
        }
    }

  //TODO eventualmente cuando se tenga memoria compartida, copiar del local al global
  //utilizar operaciones atomicas para seguridad
  //faltara sincronizar los hilos del bloque en algunos lados

}

//*****************************************************************
int main (int argc, char **argv)
{
  int i;

  //definicion de eventos de CUDA
  cudaEvent_t start, stop;
  cudaEventCreate(&start);
  cudaEventCreate(&stop);

  //lectura de imagen
  PGMImage inImg (argv[1]);

  //calculo de dimensiones
  int *cpuht;
  int w = inImg.x_dim;
  int h = inImg.y_dim;

  //secuencial, sirve para comparacion final
  CPU_HoughTran (inImg.pixels, w, h, &cpuht);

  //pre-compute values to be stored
  float *pcCos = (float *) malloc (sizeof (float) * degreeBins);
  float *pcSin = (float *) malloc (sizeof (float) * degreeBins);
  float rad = 0;

  //pre-calculo de los valores para las funciones de seno y coseno
  for (i = 0; i < degreeBins; i++)
  {
    pcCos[i] = cos (rad);
    pcSin[i] = sin (rad);
    rad += radInc;
  }

  //calculo de distancia maxima
  float rMax = sqrt (1.0 * w * w + 1.0 * h * h) / 2;
  float rScale = 2 * rMax / rBins;

  //copiamos los valores calculados a las variables globales
  cudaMemcpyToSymbol(d_Cos, pcCos, sizeof (float) * degreeBins);
  cudaMemcpyToSymbol(d_Sin, pcSin, sizeof (float) * degreeBins);

  //setup and copy data from host to device
  unsigned char *d_in, *h_in;
  int *d_hough, *h_hough;

  h_in = inImg.pixels; // h_in contiene los pixeles de la imagen

  h_hough = (int *) malloc (degreeBins * rBins * sizeof (int));

  //alocacion de memoria
  cudaMalloc ((void **) &d_in, sizeof (unsigned char) * w * h);
  cudaMalloc ((void **) &d_hough, sizeof (int) * degreeBins * rBins);
  cudaMemcpy (d_in, h_in, sizeof (unsigned char) * w * h, cudaMemcpyHostToDevice);
  cudaMemset (d_hough, 0, sizeof (int) * degreeBins * rBins);

  //execution configuration uses a 1-D grid of 1-D blocks, each made of 256 threads
  int blockNum = ceil (w * h / 256);

  cudaEventRecord(start); //inicio de medicion de tiempo

  //llamada de kernel
  GPU_HoughTranConst <<< blockNum, 256 >>> (d_in, w, h, d_hough, rMax, rScale);

  cudaEventRecord(stop); //finaliza medicion de tiempo

  //barrera de sincronizacion
  cudaDeviceSynchronize();

  //get results from device
  cudaMemcpy (h_hough, d_hough, sizeof (int) * degreeBins * rBins, cudaMemcpyDeviceToHost);

  //barrera de sincronizacion
  cudaEventSynchronize(stop);

  //comparacion de resultados CPU y GPU
  for (i = 0; i < degreeBins * rBins; i++)
  {
    if (cpuht[i] != h_hough[i] && (cpuht[i] - h_hough[i] > 1))
      printf ("Calculation mismatch at : %i %i %i\n", i, cpuht[i], h_hough[i]);
  }

  //calculo de tiempo transcurrido
  float cons_elapsed = 0;
  cudaEventElapsedTime(&cons_elapsed, start, stop);
  printf("Done!\n");

  printf("Elapsed time constant - %f ms.\n", cons_elapsed);

  //clean-up de variables y espacio en memoria
  cudaFree(d_in);
  cudaFree(d_hough);
  cudaFree(d_Cos);
  cudaFree(d_Sin);

  free(h_hough);
  free(pcCos);
  free(pcSin);

  return 0;
}
