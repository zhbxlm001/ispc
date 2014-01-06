/*
  Copyright (c) 2013, Durham University
  All rights reserved.

  Redistribution and use in source and binary forms, with or without
  modification, are permitted provided that the following conditions are
  met:

    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.

    * Redistributions in binary form must reproduce the above copyright
      notice, this list of conditions and the following disclaimer in the
      documentation and/or other materials provided with the distribution.

    * Neither the name of Durham University nor the names of its
      contributors may be used to endorse or promote products derived from
      this software without specific prior written permission.


   THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS
   IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
   TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A
   PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER
   OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
   EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
   PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
   PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
   LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
   NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
   SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.  
*/

/* Author: Tomasz Koziara */

#include "cuda_helpers.cuh"

#define cfor for
#define cif if

#define int8 char
#define int64 long

template<typename T>
__device__ inline T* __new(const int n)
{
  union
  {
    T* ptr;
    int v[2];
  }  val;
  if (programIndex == 0)
    val.ptr = new T[n];
  val.v[0] = __shfl(val.v[0],0);
  val.v[1] = __shfl(val.v[1],0);
  return val.ptr;
};

template<typename T>
__device__ inline void __delete(T* ptr)
{
  if (programIndex == 0)
    delete ptr;
};

__global__ void histogram ( int span,  int n,  int64 code[],  int pass,  int hist[])
{
  if (taskIndex >= taskCount) return;
   int start = taskIndex*span;
   int end = taskIndex == taskCount-1 ? n : start+span;
   int strip = (end-start)/programCount;
   int tail = (end-start)%programCount;
  int i = programCount*taskIndex + programIndex;
  int g [256];

  cfor (int j = 0; j < 256; j ++)
  {
    g[j] = 0;
  }

  cfor (int k = start+programIndex*strip; k < start+(programIndex+1)*strip; k ++)
  {
    unsigned int8 *c = (unsigned int8*) &code[k];

    g[c[pass]] ++;
  }

  if (programIndex == programCount-1) /* remainder is processed by the last lane */
  {
    for (int k = start+programCount*strip; k < start+programCount*strip+tail; k ++)
    {
      unsigned int8 *c = (unsigned int8*) &code[k];

      g[c[pass]] ++;
    }
  }

  cfor (int j = 0; j < 256; j ++)
  {
    hist[j*programCount*taskCount+i] = g[j];
  }
}

__global__ void permutation ( int span,  int n,  int64 code[],  int pass,  int hist[],  int64 perm[])
{
  if (taskIndex >= taskCount) return;
   int start = taskIndex*span;
   int end = taskIndex == taskCount-1 ? n : start+span;
   int strip = (end-start)/programCount;
   int tail = (end-start)%programCount;
  int i = programCount*taskIndex + programIndex;
  int g [256];

  cfor (int j = 0; j < 256; j ++)
  {
    g[j] = hist[j*programCount*taskCount+i];
  }

  cfor (int k = start+programIndex*strip; k < start+(programIndex+1)*strip; k ++)
  {
    unsigned int8 *c = (unsigned int8*) &code[k];

    int l = g[c[pass]];

    perm[l] = code[k];

    g[c[pass]] = l+1;
  }

  if (programIndex == programCount-1) /* remainder is processed by the last lane */
  {
    for (int k = start+programCount*strip; k < start+programCount*strip+tail; k ++)
    {
      unsigned int8 *c = (unsigned int8*) &code[k];

      int l = g[c[pass]];

      perm[l] = code[k];

      g[c[pass]] = l+1;
    }
  }
}

__global__ void copy ( int span,  int n,  int64 from[],  int64 to[])
{
  if (taskIndex >= taskCount) return;
   int start = taskIndex*span;
   int end = taskIndex == taskCount-1 ? n : start+span;

  for (int i = programIndex + start; i < end; i += programCount)
    if (i < end)
  {
    to[i] = from[i];
  }
}

__global__ void pack ( int span,  int n,  unsigned int code[],  int64 pair[])
{
  if (taskIndex >= taskCount) return;
   int start = taskIndex*span;
   int end = taskIndex == taskCount-1 ? n : start+span;

  for (int i = programIndex + start; i < end; i += programCount)
    if (i < end)
  {
    pair[i] = ((int64)i<<32)+code[i];
  }
}

__global__ void unpack ( int span,  int n,  int64 pair[],  int unsigned code[],  int order[])
{
  if (taskIndex >= taskCount) return;
   int start = taskIndex*span;
   int end = taskIndex == taskCount-1 ? n : start+span;

  for (int i = programIndex + start; i < end; i += programCount)
    if (i < end)
  {
    code[i] = pair[i];
    order[i] = pair[i]>>32;
  }
}

__global__ void addup ( int h[],  int g[])
{
  if (taskIndex >= taskCount) return;
   int *  u = &h[256*programCount*taskIndex];
   int i, x, y = 0;

  for (i = 0; i < 256*programCount; i ++)
  {
    x = u[i];
    u[i] = y;
    y += x;
  }

  g[taskIndex] = y;
}

__global__ void bumpup ( int h[],  int g[])
{
  if (taskIndex >= taskCount) return;
   int *  u = &h[256*programCount*taskIndex];
   int z = g[taskIndex];

  for (int i = programIndex; i < 256*programCount; i += programCount)
  {
    u[i] += z;
  }
}

inline __device__
static void prefix_sum ( int num,  int h[], int * g)
{
  int i;

  launch(num,1,1,addup)(h,g+1);
  sync;

  if (programIndex == 0)
    for (g[0] = 0, i = 1; i < num; i ++) g[i] += g[i-1];

  launch(num,1,1,bumpup)(h,g);
  sync;
}

extern "C" __global__
void sort_ispc___export ( int n,  unsigned int code[],  int order[],  int ntasks)
{
  int num = ntasks;
  int span = n / num;
  int hsize = 256*programCount*num;
  int *  hist =  __new< int>(hsize);
  int64 *  pair =  __new< int64>(n);
  int64 *  temp =  __new< int64>(n);
  int *  g =  __new<int>(num+1);
  int pass;


  launch(num,1,1,pack)(span, n, code, pair);
  sync;

  for (pass = 0; pass < 4; pass ++)
  {
    launch(num,1,1,histogram)(span, n, pair, pass, hist);
    sync;

    prefix_sum (num, hist,g);

    launch(num,1,1,permutation)(span, n, pair, pass, hist, temp);
    sync;

    launch(num,1,1,copy)(span, n, temp, pair);
    sync;
  }

  launch(num,1,1,unpack)(span, n, pair, code, order);
  sync;

  __delete(g);
  __delete(hist);
  __delete(pair);
  __delete(temp);
}

  extern "C" __host__
void sort_ispc( int n,  unsigned int code[],  int order[],  int ntasks)
{
  sort_ispc___export<<<1,32>>>(n,code,order,ntasks);
  sync;
}