/*
 ***********************************************************************************************************************
 *
 *  Copyright (c) 2018-2024 Advanced Micro Devices, Inc. All Rights Reserved.
 *
 *  Permission is hereby granted, free of charge, to any person obtaining a copy
 *  of this software and associated documentation files (the "Software"), to deal
 *  in the Software without restriction, including without limitation the rights
 *  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 *  copies of the Software, and to permit persons to whom the Software is
 *  furnished to do so, subject to the following conditions:
 *
 *  The above copyright notice and this permission notice shall be included in all
 *  copies or substantial portions of the Software.
 *
 *  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 *  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 *  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 *  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 *  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 *  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 *  SOFTWARE.
 *
 **********************************************************************************************************************/
#define RootSig "RootConstants(num32BitConstants=26, b0, visibility=SHADER_VISIBILITY_ALL), "\
                "DescriptorTable(UAV(u0, numDescriptors = 1, space = 1)),"\
                "UAV(u0, visibility=SHADER_VISIBILITY_ALL),"\
                "UAV(u1, visibility=SHADER_VISIBILITY_ALL),"\
                "UAV(u2, visibility=SHADER_VISIBILITY_ALL),"\
                "UAV(u3, visibility=SHADER_VISIBILITY_ALL),"\
                "UAV(u4, visibility=SHADER_VISIBILITY_ALL),"\
                "UAV(u5, visibility=SHADER_VISIBILITY_ALL),"\
                "UAV(u6, visibility=SHADER_VISIBILITY_ALL),"\
                "DescriptorTable(UAV(u0, numDescriptors = 1, space = 2147420894)),"\
                "CBV(b255),"\
                "UAV(u7, visibility=SHADER_VISIBILITY_ALL),"\
                "UAV(u8, visibility=SHADER_VISIBILITY_ALL)"

[[vk::binding(0, 2)]] RWBuffer<float3>                     GeometryBuffer    : register(u0, space1);

// Triangle nodes only
[[vk::binding(0, 0)]] RWByteAddressBuffer                  IndexBuffer       : register(u0);
[[vk::binding(1, 0)]] RWStructuredBuffer<float4>           TransformBuffer   : register(u1);

[[vk::binding(2, 0)]] globallycoherent RWByteAddressBuffer DstMetadata       : register(u2);
[[vk::binding(3, 0)]] RWByteAddressBuffer                  ScratchBuffer     : register(u3);
[[vk::binding(4, 0)]] RWByteAddressBuffer                  ScratchGlobal     : register(u4);
[[vk::binding(5, 0)]] RWByteAddressBuffer                  SrcBuffer         : register(u5);
[[vk::binding(6, 0)]] RWByteAddressBuffer                  IndirectArgBuffer : register(u6);

// unused buffer
[[vk::binding(7, 0)]] globallycoherent RWByteAddressBuffer DstBuffer         : register(u7);
[[vk::binding(8, 0)]] RWByteAddressBuffer                  EmitBuffer        : register(u8);

#include "Common.hlsl"
#include "BuildCommon.hlsl"
#include "BuildCommonScratch.hlsl"
#include "EncodeCommon.hlsl"
#include "EncodePairedTriangle.hlsl"

[[vk::binding(0, 1)]] ConstantBuffer<GeometryArgs> ShaderConstants : register(b0);

//=====================================================================================================================
[RootSignature(RootSig)]
[numthreads(BUILD_THREADGROUP_SIZE, 1, 1)]
//=====================================================================================================================
void EncodeTriangleNodes(
    in uint3 globalThreadId : SV_DispatchThreadID,
    in uint localId         : SV_GroupThreadID)
{
#if INDIRECT_BUILD
    // Sourced from Indirect Buffers
    const IndirectBuildOffset buildOffsetInfo = IndirectArgBuffer.Load<IndirectBuildOffset>(0);

    const uint numPrimitives      = buildOffsetInfo.primitiveCount;
    const uint primitiveOffset    = ComputePrimitiveOffset(ShaderConstants);
    const uint vertexOffset       = buildOffsetInfo.firstVertex;
#else
    const uint numPrimitives      = ShaderConstants.NumPrimitives;
    const uint primitiveOffset    = ShaderConstants.PrimitiveOffset;
    const uint vertexOffset       = 0;
#endif

    const bool enableEarlyPairCompression =
        (Settings.enableEarlyPairCompression == true) && (IsUpdate() == false);

    if (globalThreadId.x == 0)
    {
        WriteGeometryInfo(
            ShaderConstants, primitiveOffset, ShaderConstants.NumPrimitives, DECODE_PRIMITIVE_STRIDE_TRIANGLE);
    }

    uint primitiveIndex = globalThreadId.x;

    if (primitiveIndex < numPrimitives)
    {
        if (enableEarlyPairCompression)
        {
            EncodePairedTriangleNode(GeometryBuffer,
                                     IndexBuffer,
                                     TransformBuffer,
                                     ShaderConstants,
                                     primitiveIndex,
                                     globalThreadId.x,
                                     primitiveOffset,
                                     vertexOffset);
        }
        else
        {
            EncodeTriangleNode(GeometryBuffer,
                               IndexBuffer,
                               TransformBuffer,
                               ShaderConstants,
                               primitiveIndex,
                               primitiveOffset,
                               vertexOffset,
                               true);
        }
    }

    const uint wavePrimCount = WaveActiveCountBits(primitiveIndex < numPrimitives);
    if (WaveIsFirstLane())
    {
        IncrementTaskCounter(ShaderConstants.encodeTaskCounterScratchOffset + ENCODE_TASK_COUNTER_NUM_PRIMITIVES_OFFSET,
                             wavePrimCount);
    }
}

//=====================================================================================================================
[RootSignature(RootSig)]
[numthreads(BUILD_THREADGROUP_SIZE, 1, 1)]
//=====================================================================================================================
void EncodeAABBNodes(
    in uint3 globalThreadId : SV_DispatchThreadID)
{
#if INDIRECT_BUILD
    // Sourced from Indirect Buffers
    const IndirectBuildOffset buildOffsetInfo = IndirectArgBuffer.Load<IndirectBuildOffset>(0);

    const uint numPrimitives      = buildOffsetInfo.primitiveCount;
    const uint primitiveOffset    = ComputePrimitiveOffset(ShaderConstants);
#else
    const uint numPrimitives      = ShaderConstants.NumPrimitives;
    const uint primitiveOffset    = ShaderConstants.PrimitiveOffset;
#endif

    if (globalThreadId.x == 0)
    {
        WriteGeometryInfo(ShaderConstants, primitiveOffset, numPrimitives, DECODE_PRIMITIVE_STRIDE_AABB);
    }

    uint primitiveIndex = globalThreadId.x;
    if (primitiveIndex < ShaderConstants.NumPrimitives)
    {
        EncodeAabbNode(GeometryBuffer,
                       IndexBuffer,
                       TransformBuffer,
                       ShaderConstants,
                       primitiveIndex,
                       primitiveOffset,
                       true);
    }

    const uint wavePrimCount = WaveActiveCountBits(primitiveIndex < ShaderConstants.NumPrimitives);
    if (WaveIsFirstLane())
    {
        IncrementTaskCounter(ShaderConstants.encodeTaskCounterScratchOffset + ENCODE_TASK_COUNTER_NUM_PRIMITIVES_OFFSET,
                             wavePrimCount);
    }
}

//=====================================================================================================================
[RootSignature(RootSig)]
[numthreads(BUILD_THREADGROUP_SIZE, 1, 1)]
//=====================================================================================================================
void CountTrianglePairs(
    in uint globalId : SV_DispatchThreadID,
    in uint localId  : SV_GroupThreadID)
{
#if INDIRECT_BUILD
    // Sourced from Indirect Buffers
    const IndirectBuildOffset buildOffsetInfo = IndirectArgBuffer.Load<IndirectBuildOffset>(0);

    const uint numPrimitives      = buildOffsetInfo.primitiveCount;
    const uint primitiveOffset    = ComputePrimitiveOffset(ShaderConstants);
    const uint vertexOffset       = buildOffsetInfo.firstVertex;
#else
    const uint numPrimitives      = ShaderConstants.NumPrimitives;
    const uint primitiveOffset    = ShaderConstants.PrimitiveOffset;
    const uint vertexOffset       = 0;
#endif

    // Reset geometry primitive reference count in result buffer
    const uint basePrimRefCountOffset =
        ShaderConstants.metadataSizeInBytes + ShaderConstants.DestLeafByteOffset;

    const uint primRefCountOffset =
        basePrimRefCountOffset + ComputePrimRefCountBlockOffset(ShaderConstants.blockOffset, globalId);

    if (globalId < numPrimitives)
    {
        const int pairInfo = TryPairTriangleImpl(GeometryBuffer,
                                                 IndexBuffer,
                                                 TransformBuffer,
                                                 ShaderConstants,
                                                 globalId,
                                                 vertexOffset);

        // Count quads produced by the current wave. Note, this includes unpaired triangles as well
        // (marked with a value of -1).
        const bool isActivePrimRef = (pairInfo >= -1);
        const uint wavePrimRefCount = WaveActiveCountBits(isActivePrimRef);

        if (WaveIsFirstLane())
        {
            DstMetadata.Store(primRefCountOffset, wavePrimRefCount);
        }
    }
}
