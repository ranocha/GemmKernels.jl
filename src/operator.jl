export Operator
module Operator

using CUDA
using GemmKernels
using GemmKernels.Tiling
using GemmKernels: LocalArray
using LLVMLoopInfo: @loopinfo
using Base: setindex

# -------------------------------------
# Default definition for padded layouts
# -------------------------------------

for f in (:fragtype_a, :fragtype_b, :fragtype_accum, :load_a, :load_b, :load_c, :store_d)
    @eval @inline $f(op, ::Type{Layout.Padded{L, P}}, args...) where {L, P} = $f(op, L, args...)
end


# ---
# FPU
# ---

abstract type GeneralFPUOp{M, N, K, DT, CT} end

@inline shape(::Type{<:GeneralFPUOp{M, N, K, DT, CT}}) where {M, N, K, DT, CT} = (M = M, N = N, K = K)

for (layout_type, convert_index_func) in [
                                        (Layout.AlignedColMajor, identity),
                                        (Layout.AlignedRowMajor, x -> reverse(Tuple(x)))
                                       ]
    @eval begin
        @inline fragtype_a(::Type{<:GeneralFPUOp{M, N, K, DT, CT}}, ::Type{$layout_type{CT}}) where {M, N, K, DT, CT} = NTuple{M * K ÷ 4, CT}
        @inline fragtype_b(::Type{<:GeneralFPUOp{M, N, K, DT, CT}}, ::Type{$layout_type{CT}}) where {M, N, K, DT, CT} = NTuple{K * N ÷ 8, CT}

        @inline function fragtype_accum(::Type{<:GeneralFPUOp{M, N, K, DT, CT}}, ::Type{$layout_type{DT}}) where {M, N, K, DT, CT}
            return NTuple{M * N ÷ 32, DT}
        end

        @inline function load_a(::Type{<:GeneralFPUOp{M, N, K, DT, CT}}, ::Type{$layout_type{CT}}, workspace, tile::Tile) where {M, N, K, DT, CT}
            laneId = (threadIdx().x - 1) % 32 + 1

            op_y = (laneId - 1) % 4 + 1
            y, x = (tile.base.M + tile.offset.M + op_y, tile.base.K + tile.offset.K + 1)

            frag = LocalArray{Tuple{M ÷ 4, K}, CT}(undef)
            @loopinfo unroll for m = 1 : M ÷ 4
                @loopinfo unroll for k = 1 : K
                    y_layout, x_layout = $convert_index_func((y + 4 * (m - 1), x + (k - 1)))
                    @inbounds frag = setindex(frag, workspace[y_layout, x_layout], m, k)
                end
            end

            return NTuple{M * K ÷ 4, CT}(frag)
        end

        @inline function load_b(::Type{<:GeneralFPUOp{M, N, K, DT, CT}}, ::Type{$layout_type{CT}}, workspace, tile::Tile) where {M, N, K, DT, CT}
            laneId = (threadIdx().x - 1) % 32 + 1

            op_x = (laneId - 1) ÷ 4 + 1
            y, x = (tile.base.K + tile.offset.K + 1, tile.base.N + tile.offset.N + op_x)

            frag = LocalArray{Tuple{K, N ÷ 8}, CT}(undef)
            @loopinfo unroll for n = 1 : N ÷ 8
                @loopinfo unroll for k = 1 : K
                    y_layout, x_layout = $convert_index_func((y + (k - 1), x + 8 * (n - 1)))
                    @inbounds frag = setindex(frag, workspace[y_layout, x_layout], k, n)
                end
            end

            return NTuple{K * N ÷ 8, CT}(frag)
        end

        @inline function load_c(::Type{<:GeneralFPUOp{M, N, K, DT, CT}}, ::Type{$layout_type{DT}}, workspace, tile::Tile) where {M, N, K, DT, CT}
            laneId = (threadIdx().x - 1) % 32 + 1

            op_y = (laneId - 1) % 4 + 1
            op_x = (laneId - 1) ÷ 4 + 1

            y, x = (tile.base.M + tile.offset.M + op_y, tile.base.N + tile.offset.N + op_x)

            frag = LocalArray{Tuple{M ÷ 4, N ÷ 8}, DT}(undef)
            @loopinfo unroll for m = 1 : M ÷ 4
                @loopinfo unroll for n = 1 : N ÷ 8
                    @inbounds frag = setindex(frag, workspace[y + 4 * (m - 1), x + 8 * (n - 1)], m, n)
                end
            end

            return NTuple{M * N ÷ 32, DT}(frag)
        end

        @inline function store_d(::Type{<:GeneralFPUOp{M, N, K, DT, CT}}, ::Type{$layout_type{DT}}, workspace, frag, tile::Tile) where {M, N, K, DT, CT}
            laneId = (threadIdx().x - 1) % 32 + 1

            op_y = (laneId - 1) % 4 + 1
            op_x = (laneId - 1) ÷ 4 + 1

            y, x = (tile.base.M + tile.offset.M + op_y, tile.base.N + tile.offset.N + op_x)

            frag = LocalArray{Tuple{M ÷ 4, N ÷ 8}, DT}(frag)
            @loopinfo unroll for m = 1 : M ÷ 4
                @loopinfo unroll for n = 1 : N ÷ 8
                    @inbounds workspace[y + 4 * (m - 1), x + 8 * (n - 1)] = frag[m, n]
                end
            end
        end
    end
end

abstract type FPUOp{M, N, K, DT, CT} <: GeneralFPUOp{M, N, K, DT, CT} end
function operator_fma(::Type{FPUOp{M, N, K, DT, CT}}, a::CT, b::CT, c::DT) where {M, N, K, DT, CT}
    return fma(a, b, c)
end

abstract type TropicalFPUOp{M, N, K, DT, CT} <: GeneralFPUOp{M, N, K, DT, CT} end
function operator_fma(::Type{TropicalFPUOp{M, N, K, DT, CT}}, a::CT, b::CT, c::DT) where {M, N, K, DT, CT}
    return max(a + b, c)
end

@inline function mma(operator_type::Type{<:GeneralFPUOp{M, N, K, DT, CT}}, a_frag, b_frag, c_frag) where {M, N, K, DT, CT}
    a_frag = LocalArray{Tuple{M ÷ 4, K}, CT}(a_frag)
    b_frag = LocalArray{Tuple{K, N ÷ 8}, CT}(b_frag)
    c_frag = LocalArray{Tuple{M ÷ 4, N ÷ 8}, DT}(c_frag)

    @loopinfo unroll for m = 1 : M ÷ 4
        @loopinfo unroll for n = 1 : N ÷ 8
            @loopinfo unroll for k = 1 : K
                @inbounds c_frag = setindex(
                    c_frag,
                    operator_fma(operator_type, a_frag[m, k], b_frag[k, n], c_frag[m, n]),
                    m, n
                )
            end
        end
    end

    return NTuple{M * N ÷ 32, DT}(c_frag)
end

# ----
# WMMA
# ----

struct WMMAOp{M, N, K, T} end

@inline shape(::Type{WMMAOp{M, N, K, T}}) where {M, N, K, T} = (M = M, N = N, K = K)

# convert_index_func: function used to transpose the index in case of a row-major layout
for (layout_type, wmma_layout_type, convert_index_func) in [
                                        (Layout.AlignedColMajor, WMMA.ColMajor, identity),
                                        (Layout.AlignedRowMajor, WMMA.RowMajor, x -> reverse(Tuple(x)))
                                       ]
    @eval begin
        @inline fragtype_a(::Type{WMMAOp{16, 16, 16, T}}, ::Type{$layout_type{Float16}}) where {T} = WMMA.Fragment{16, 16, 16, 16, Float16, $wmma_layout_type, WMMA.MatrixA}
        @inline fragtype_b(::Type{WMMAOp{16, 16, 16, T}}, ::Type{$layout_type{Float16}}) where {T} = WMMA.Fragment{16, 16, 16, 16, Float16, $wmma_layout_type, WMMA.MatrixB}
        @inline fragtype_accum(::Type{WMMAOp{16, 16, 16, T}}, ::Type{$layout_type{T}}) where {T} = WMMA.Fragment{16, 16, 16, 8, T, WMMA.Unspecified, WMMA.Accumulator}

        @inline function load_a(::Type{WMMAOp{M, N, K, T}}, ::Type{$layout_type{Float16}}, workspace, tile::Tile) where {M, N, K, T}
            conf = WMMA.Config{M, N, K, T}

            linear_base = linearise($convert_index_func(tile.base), size(workspace))
            linear_offset = linearise($convert_index_func(tile.offset), size(workspace))

            ptr = pointer(workspace, linear_base) + (linear_offset - 1) * sizeof(Float16)
            return WMMA.load_a(ptr, size(workspace, 1), $wmma_layout_type, conf)
        end

        @inline function load_b(::Type{WMMAOp{M, N, K, T}}, ::Type{$layout_type{Float16}}, workspace, tile::Tile) where {M, N, K, T}
            conf = WMMA.Config{M, N, K, T}

            linear_base = linearise($convert_index_func(tile.base), size(workspace))
            linear_offset = linearise($convert_index_func(tile.offset), size(workspace))

            ptr = pointer(workspace, linear_base) + (linear_offset - 1) * sizeof(Float16)
            return WMMA.load_b(ptr, size(workspace, 1), $wmma_layout_type, conf)
        end

        @inline function load_c(::Type{WMMAOp{M, N, K, T}}, ::Type{$layout_type{T}}, workspace, tile::Tile) where {M, N, K, T}
            conf = WMMA.Config{M, N, K, T}

            linear_base = linearise($convert_index_func(tile.base), size(workspace))
            linear_offset = linearise($convert_index_func(tile.offset), size(workspace))

            ptr = pointer(workspace, linear_base) + (linear_offset - 1) * sizeof(T)
            return WMMA.load_c(ptr, size(workspace, 1), $wmma_layout_type, conf)
        end

        @inline function store_d(::Type{WMMAOp{M, N, K, T}}, ::Type{$layout_type{T}}, workspace, frag, tile::Tile) where {M, N, K, T}
            conf = WMMA.Config{M, N, K, T}

            linear_base = linearise($convert_index_func(tile.base), size(workspace))
            linear_offset = linearise($convert_index_func(tile.offset), size(workspace))

            ptr = pointer(workspace, linear_base) + (linear_offset - 1) * sizeof(T)
            WMMA.store_d(ptr, frag, size(workspace, 1), $wmma_layout_type, conf)
        end
    end
end

function mma(::Type{WMMAOp{M, N, K, T}}, a_frag, b_frag, c_frag) where {M, N, K, T}
    conf = WMMA.Config{M, N, K, T}
    return WMMA.mma(a_frag, b_frag, c_frag, conf)
end

# -----------
# WMMAComplex
# -----------

struct WMMAComplexOp{M, N, K} end

@inline shape(::Type{WMMAComplexOp{M, N, K}}) where {M, N, K} = (M = M, N = N, K = K)

# convert_index_func: function used to transpose the index in case of a row-major layout
for (layout_type, wmma_layout_type, convert_index_func) in [
                                        (Layout.SplitColMajor, WMMA.ColMajor, identity),
                                        (Layout.SplitRowMajor, WMMA.RowMajor, x -> reverse(Tuple(x))),
                                       ]
    @eval begin
        @inline fragtype_a(::Type{WMMAComplexOp{16, 16, 16}}, ::Type{$layout_type{Float16}}) = NTuple{2, WMMA.Fragment{16, 16, 16, 16, Float16, $wmma_layout_type, WMMA.MatrixA}}
        @inline fragtype_b(::Type{WMMAComplexOp{16, 16, 16}}, ::Type{$layout_type{Float16}}) = NTuple{2, WMMA.Fragment{16, 16, 16, 16, Float16, $wmma_layout_type, WMMA.MatrixB}}
        @inline fragtype_accum(::Type{WMMAComplexOp{16, 16, 16}}, ::Type{$layout_type{Float32}}) = NTuple{2, WMMA.Fragment{16, 16, 16, 8, Float32, WMMA.Unspecified, WMMA.Accumulator}}

        @inline function load_a(::Type{WMMAComplexOp{M, N, K}}, ::Type{$layout_type{Float16}}, workspace, tile::Tile) where {M, N, K}
            conf = WMMA.Config{16, 16, 16, Float32}
            ind = linearise($convert_index_func(tile.index), (size(workspace)[1], size(workspace)[2]))

            return (WMMA.load_a(pointer(workspace, ind), size(workspace)[1], $wmma_layout_type, conf),
                    WMMA.load_a(pointer(workspace, ind + size(workspace)[1] * size(workspace)[2]), size(workspace)[1], $wmma_layout_type, conf))
        end

        @inline function load_b(::Type{WMMAComplexOp{M, N, K}}, ::Type{$layout_type{Float16}}, workspace, tile::Tile) where {M, N, K}
            conf = WMMA.Config{16, 16, 16, Float32}
            ind = linearise($convert_index_func(tile.index), (size(workspace)[1], size(workspace)[2]))

            return (WMMA.load_b(pointer(workspace, ind), size(workspace)[1], $wmma_layout_type, conf),
                    WMMA.load_b(pointer(workspace, ind + size(workspace)[1] * size(workspace)[2]), size(workspace)[1], $wmma_layout_type, conf))
        end

        @inline function load_c(::Type{WMMAComplexOp{M, N, K}}, ::Type{$layout_type{Float32}}, workspace, tile::Tile) where {M, N, K}
            conf = WMMA.Config{M, N, K, Float32}
            ind = linearise($convert_index_func(tile.index), (size(workspace)[1], size(workspace)[2]))

            return (WMMA.load_c(pointer(workspace, ind), size(workspace)[1], $wmma_layout_type, conf),
                    WMMA.load_c(pointer(workspace, ind + size(workspace)[1] * size(workspace)[2]), size(workspace)[1], $wmma_layout_type, conf))
        end

        @inline function store_d(::Type{WMMAComplexOp{M, N, K}}, ::Type{$layout_type{Float32}}, workspace, frag, tile::Tile) where {M, N, K}
            conf = WMMA.Config{M, N, K, Float32}
            ind = linearise($convert_index_func(tile.index), (size(workspace)[1], size(workspace)[2]))

            WMMA.store_d(pointer(workspace, ind), frag[1], size(workspace)[1], $wmma_layout_type, conf)
            WMMA.store_d(pointer(workspace, ind + size(workspace)[1] * size(workspace)[2]), frag[2], size(workspace)[1], $wmma_layout_type, conf)
        end
    end
end

using LLVM

@inline function mma(::Type{WMMAComplexOp{M, N, K}}, a_frag, b_frag, c_frag) where {M, N, K}
    conf = WMMA.Config{16, 16, 16, Float32}

    c_re = c_frag[1]
    c_im = c_frag[2]

    c_re = WMMA.mma(a_frag[1],  b_frag[1], c_re, conf)
    c_re = WMMA.mma(.-(a_frag[2]), b_frag[2], c_re, conf)

    c_im = WMMA.mma(a_frag[1], b_frag[2], c_im, conf)
    c_im = WMMA.mma(a_frag[2], b_frag[1], c_im, conf)

    return (c_re, c_im)
end

# --------
# WMMADual
# --------

struct WMMADualOp{M, N, K} end

@inline shape(::Type{WMMADualOp{M, N, K}}) where {M, N, K} = (M = M, N = N, K = K)

@inline fragtype_a(::Type{WMMADualOp{16, 16, 16}}, ::Type{Layout.SplitColMajor{Float16}}) = NTuple{2, WMMA.Fragment{16, 16, 16, 16, Float16, WMMA.ColMajor, WMMA.MatrixA}}
@inline fragtype_b(::Type{WMMADualOp{16, 16, 16}}, ::Type{Layout.SplitColMajor{Float16}}) = NTuple{2, WMMA.Fragment{16, 16, 16, 16, Float16, WMMA.ColMajor, WMMA.MatrixB}}
@inline fragtype_accum(::Type{WMMADualOp{16, 16, 16}}, ::Type{Layout.SplitColMajor{Float32}}) = NTuple{2, WMMA.Fragment{16, 16, 16, 8, Float32, WMMA.Unspecified, WMMA.Accumulator}}

@inline function load_a(::Type{WMMADualOp{M, N, K}}, ::Type{Layout.SplitColMajor{Float16}}, workspace, tile::Tile) where {M, N, K}
    conf = WMMA.Config{16, 16, 16, Float32}
    ind = linearise(tile.index, (size(workspace)[1], size(workspace)[2]))

    return (WMMA.load_a(pointer(workspace, ind), size(workspace)[1], WMMA.ColMajor, conf),
            WMMA.load_a(pointer(workspace, ind + size(workspace)[1] * size(workspace)[2]), size(workspace)[1], WMMA.ColMajor, conf))
end

@inline function load_b(::Type{WMMADualOp{M, N, K}}, ::Type{Layout.SplitColMajor{Float16}}, workspace, tile::Tile) where {M, N, K}
    conf = WMMA.Config{16, 16, 16, Float32}
    ind = linearise(tile.index, (size(workspace)[1], size(workspace)[2]))

    return (WMMA.load_b(pointer(workspace, ind), size(workspace)[1], WMMA.ColMajor, conf),
            WMMA.load_b(pointer(workspace, ind + size(workspace)[1] * size(workspace)[2]), size(workspace)[1], WMMA.ColMajor, conf))
end

@inline function load_c(::Type{WMMADualOp{M, N, K}}, ::Type{Layout.SplitColMajor{Float32}}, workspace, tile::Tile) where {M, N, K}
    conf = WMMA.Config{M, N, K, Float32}
    ind = linearise(tile.index, (size(workspace)[1], size(workspace)[2]))

    return (WMMA.load_c(pointer(workspace, ind), size(workspace)[1], WMMA.ColMajor, conf),
            WMMA.load_c(pointer(workspace, ind + size(workspace)[1] * size(workspace)[2]), size(workspace)[1], WMMA.ColMajor, conf))
end

@inline function store_d(::Type{WMMADualOp{M, N, K}}, ::Type{Layout.SplitColMajor{Float32}}, workspace, frag, tile::Tile) where {M, N, K}
    conf = WMMA.Config{M, N, K, Float32}
    ind = linearise(tile.index, (size(workspace)[1], size(workspace)[2]))

    WMMA.store_d(pointer(workspace, ind), frag[1], size(workspace)[1], WMMA.ColMajor, conf)
    WMMA.store_d(pointer(workspace, ind + size(workspace)[1] * size(workspace)[2]), frag[2], size(workspace)[1], WMMA.ColMajor, conf)
end

@inline function mma(::Type{WMMADualOp{M, N, K}}, a_frag, b_frag, c_frag) where {M, N, K}
    conf = WMMA.Config{16, 16, 16, Float32}

    c_re = c_frag[1]
    c_du = c_frag[2]

    c_re = WMMA.mma(a_frag[1],  b_frag[1], c_re, conf)

    c_du = WMMA.mma(a_frag[1], b_frag[2], c_du, conf)
    c_du = WMMA.mma(a_frag[2], b_frag[1], c_du, conf)

    return (c_re, c_du)
end

end
