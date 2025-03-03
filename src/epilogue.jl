export Epilogue
module Epilogue

using CUDA
using GemmKernels
using GemmKernels.Tiling
using LLVMLoopInfo: @loopinfo

# ----------------
# Default epilogue
# ----------------

struct Default end

@inline function (ep::Default)(conf::GemmKernels.Config, d, shmem_d, transform)
    # Constants
    block_i = (blockIdx().x - 1) * conf.block_shape.M
    block_j = (blockIdx().y - 1) * conf.block_shape.N

    warpId = (threadIdx().x - 1) ÷ 32 + 1
    laneId = (threadIdx().x - 1) % 32 + 1

    gemm_sz = Tile(conf.matmul_shape)
    block_tile = Tile(conf.block_shape)

    # Cooperatively store a block_shape.M x block_shape.N tile of D from shared to global memory within one threadblock
    @loopinfo unroll for warp_tile = parallellise(block_tile.MN, Tile(conf.mem_cd_warp), warpId, conf.warps_per_block)
        @loopinfo unroll for thread_tile = parallellise(warp_tile, Tile(conf.mem_cd_thread), laneId, 32)
            x = @inbounds Layout.load(conf.shared_d_layout, shmem_d, thread_tile)
            x = transform(x, thread_tile)
            @inbounds Layout.store!(conf.global_d_layout, d, x, translate_base(thread_tile, (M = block_i, N = block_j)))
        end
    end
end

# -------------
# Bias epilogue
# -------------

struct Bias{B}
    bias_pointer::B
end

@inline function apply_bias(x, bias_pointer::CuPtr{Float32}, thread_tile)
    dev_ptr = reinterpret(Core.LLVMPtr{Float32, AS.Global}, bias_pointer)

    # Load bias value for this column
    col = thread_tile.index.N + 1
    b = unsafe_load(dev_ptr, col)

    return ntuple(k -> VecElement{Float32}(x[k].value + b), Val(4))
end

@inline function (ep::Bias{B})(conf::GemmKernels.Config, d, shmem_d, transform) where {B}
    # Constants
    block_i = (blockIdx().x - 1) * conf.block_shape.M
    block_j = (blockIdx().y - 1) * conf.block_shape.N

    warpId = (threadIdx().x - 1) ÷ 32 + 1
    laneId = (threadIdx().x - 1) % 32 + 1

    gemm_sz = Tile(conf.matmul_shape)
    block_tile = Tile(conf.block_shape)

    # Cooperatively store a block_shape.M x block_shape.N tile of D from shared to global memory within one threadblock
    @loopinfo unroll for warp_tile = parallellise(block_tile.MN, Tile(conf.mem_cd_warp), warpId, conf.warps_per_block)
        @loopinfo unroll for thread_tile = parallellise(warp_tile, Tile(conf.mem_cd_thread), laneId, 32)
            x = @inbounds Layout.load(conf.shared_d_layout, shmem_d, thread_tile)
            x = apply_bias(x, ep.bias_pointer, translate_base(thread_tile, (M = block_i, N = block_j)))
            x = transform(x, thread_tile)
            @inbounds Layout.store!(conf.global_d_layout, d, x, translate_base(thread_tile, (M = block_i, N = block_j)))
        end
    end
end

end
