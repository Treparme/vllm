#include <cudaTypedefs.h>

#include <torch/all.h>

#include <ATen/cuda/CUDAContext.h>

#include <iostream>
#include <sstream>
#include <vector>

#include "cutlass/cutlass.h"

#include "cute/tensor.hpp"
#include "cute/atom/mma_atom.hpp"
#include "cutlass/numeric_types.h"

#include "cutlass/gemm/device/gemm_universal_adapter.h"
#include "cutlass/gemm/kernel/gemm_universal.hpp"
#include "cutlass/gemm/kernel/tile_scheduler_params.h"
#include "cutlass/epilogue/collective/collective_builder.hpp"
#include "cutlass/gemm/collective/collective_builder.hpp"

#include "util/broadcast_load_epilogue_c3x.hpp"
#include "util/common.hpp"

using namespace cute;

/*
   This file defines quantized GEMM operations using the CUTLASS 3.x API, for
   NVIDIA GPUs with sm90a (Hopper) or later.

   Epilogue functions can be defined to post-process the output before it is
   written to GPU memory.
   Epilogues must contain a public type named EVTCompute of type Sm90EVT,
   as well as a static prepare_args function that constructs an
   EVTCompute::Arguments struct.
*/

namespace {

// A wrapper for the GEMM kernel that is used to guard against compilation on
// architectures that will never use the kernel. The purpose of this is to
// reduce the size of the compiled binary.
// __CUDA_ARCH__ is not defined in host code, so this lets us smuggle the ifdef
// into code that will be executed on the device where it is defined.
template <typename Kernel>
struct enable_sm90_or_later : Kernel {
  template <typename... Args>
  CUTLASS_DEVICE void operator()(Args&&... args) {
  #if defined __CUDA_ARCH__ && __CUDA_ARCH__ >= 900
    Kernel::operator()(std::forward<Args>(args)...);
  #endif
  }
};

/*
 * This class provides the common load descriptors for the
 * ScaledEpilogue[...] classes
 */
template <typename ElementAcc, typename ElementD, typename EpilogueDescriptor>
struct ScaledEpilogueBase {
 protected:
  using Accum = cutlass::epilogue::fusion::Sm90AccFetch;

  template <typename T>
  using ColOrScalarLoad = cutlass::epilogue::fusion::Sm90ColOrScalarBroadcast<
      0 /*Stages*/, typename EpilogueDescriptor::TileShape, T,
      Stride<Int<1>, Int<0>, Int<0>>>;

  template <typename T>
  using RowOrScalarLoad = cutlass::epilogue::fusion::Sm90RowOrScalarBroadcast<
      0 /*Stages*/, typename EpilogueDescriptor::TileShape, T,
      Stride<Int<0>, Int<1>, Int<0>>>;

  // Don't want to support nullptr by default
  template <typename T, bool EnableNullPtr = false>
  using ColLoad = cutlass::epilogue::fusion::Sm90ColBroadcast<
      0 /*Stages*/, typename EpilogueDescriptor::TileShape, T, T,
      Stride<Int<1>, Int<0>, Int<0>>, 128 / sizeof_bits_v<T>, EnableNullPtr>;

  // Don't want to support nullptr by default
  template <typename T, bool EnableNullPtr = false>
  using RowLoad = cutlass::epilogue::fusion::Sm90RowBroadcast<
      0 /*Stages*/, typename EpilogueDescriptor::TileShape, T, T,
      Stride<Int<0>, Int<1>, Int<0>>, 128 / sizeof_bits_v<T>, EnableNullPtr>;

  // This utility function constructs the arguments for the load descriptors
  // from a tensor. It can handle both row and column, as well as row/column or
  // scalar cases.
  template <typename Descriptor, typename T>
  static auto args_from_tensor(torch::Tensor const& tensor) {
    using Arguments = typename Descriptor::Arguments;
    auto* data_ptr = static_cast<T*>(tensor.data_ptr());
    if constexpr (std::is_same_v<Descriptor, ColOrScalarLoad<T>> ||
                  std::is_same_v<Descriptor, RowOrScalarLoad<T>>) {
      return Arguments{data_ptr, tensor.numel() != 1};
    } else {
      static_assert(!std::is_same_v<Descriptor, ColLoad<T, true>> &&
                    !std::is_same_v<Descriptor, RowLoad<T, true>>);
      return Arguments{data_ptr};
    }
  }

  // This overload handles the case where there might not be a tensor, in which
  // case a nullptr is passed and a constant (0) is used.
  template <typename Descriptor, typename T>
  static auto args_from_tensor(c10::optional<torch::Tensor> const& tensor) {
    using Arguments = typename Descriptor::Arguments;
    auto* data_ptr = tensor ? static_cast<T*>(tensor->data_ptr()) : nullptr;
    static_assert(std::is_same_v<Descriptor, ColLoad<T, true>> ||
                  std::is_same_v<Descriptor, RowLoad<T, true>>);
    return Arguments{data_ptr};
  }
};

/*
   This epilogue function defines a quantized GEMM operation similar to
   torch.scaled_mm_.

   A and B may be both either int8 or fp8_e4m3. A can be
   quantized per-tensor or per-row. B can be quantized per-tensor or per-column.
   Any combination of per-tensor and per-row or column is supported.
   A and B must have symmetric quantization (zero point == 0).

   So the GEMM operation is D = (a_scales * A) (b_scales * B), where the
   scales are applied elementwise with numpy-style broadcasting.

   ScaleA and ScaleB define the epilogue functions that apply the scales for
   the A and B operands respectively. These scales may be either per-tensor or
   per row or column.
*/
template <typename ElementAcc, typename ElementD, typename EpilogueDescriptor>
struct ScaledEpilogue
    : private ScaledEpilogueBase<ElementAcc, ElementD, EpilogueDescriptor> {
 private:
  using SUPER = ScaledEpilogueBase<ElementAcc, ElementD, EpilogueDescriptor>;
  using Accum = typename SUPER::Accum;
  using ScaleA = typename SUPER::template ColOrScalarLoad<float>;
  using ScaleB = typename SUPER::template RowOrScalarLoad<float>;

  using Compute0 = cutlass::epilogue::fusion::Sm90Compute<
      cutlass::multiplies, float, float,
      cutlass::FloatRoundStyle::round_to_nearest>;

  using EVTCompute0 =
      cutlass::epilogue::fusion::Sm90EVT<Compute0, ScaleB, Accum>;

  using Compute1 = cutlass::epilogue::fusion::Sm90Compute<
      cutlass::multiplies, ElementD, float,
      cutlass::FloatRoundStyle::round_to_nearest>;

 public:
  using EVTCompute =
      cutlass::epilogue::fusion::Sm90EVT<Compute1, ScaleA, EVTCompute0>;
  using ArgumentType = typename EVTCompute::Arguments;

  static ArgumentType prepare_args(torch::Tensor const& a_scales,
                                   torch::Tensor const& b_scales) {
    auto a_args = SUPER::template args_from_tensor<ScaleA, float>(a_scales);
    auto b_args = SUPER::template args_from_tensor<ScaleB, float>(b_scales);

    typename EVTCompute0::Arguments evt0_args{b_args};
    return ArgumentType{a_args, evt0_args};
  }
};

/*
 * This epilogue performs the same operation as ScaledEpilogue, but adds a bias.
 * This bias can also be used in the per-tensor azp case, where the activation
 * zero point (azp) is used to compute an azp correction term,
 * which is folded into the bias.
 *
 * The bias tensor must be per-output channel.
 * ScaleA and ScaleB can be per-tensor or per-token/per-channel.
 */
template <typename ElementAcc, typename ElementD, typename EpilogueDescriptor>
struct ScaledEpilogueBias
    : private ScaledEpilogueBase<ElementAcc, ElementD, EpilogueDescriptor> {
 private:
  using SUPER = ScaledEpilogueBase<ElementAcc, ElementD, EpilogueDescriptor>;
  using Accum = typename SUPER::Accum;
  using ScaleA = typename SUPER::template ColOrScalarLoad<float>;
  using ScaleB = typename SUPER::template RowOrScalarLoad<float>;
  using Bias = typename SUPER::template RowLoad<ElementD>;

  using Compute0 = cutlass::epilogue::fusion::Sm90Compute<
      cutlass::multiplies, float, float,
      cutlass::FloatRoundStyle::round_to_nearest>;

  using EVTCompute0 =
      cutlass::epilogue::fusion::Sm90EVT<Compute0, ScaleB, Accum>;

  using Compute1 = cutlass::epilogue::fusion::Sm90Compute<
      cutlass::multiply_add, ElementD, float,
      cutlass::FloatRoundStyle::round_to_nearest>;

 public:
  using EVTCompute =
      cutlass::epilogue::fusion::Sm90EVT<Compute1, ScaleA, EVTCompute0, Bias>;

  using ArgumentType = typename EVTCompute::Arguments;
  static ArgumentType prepare_args(torch::Tensor const& a_scales,
                                   torch::Tensor const& b_scales,
                                   torch::Tensor const& bias) {
    auto a_args = SUPER::template args_from_tensor<ScaleA, float>(a_scales);
    auto b_args = SUPER::template args_from_tensor<ScaleB, float>(b_scales);
    auto bias_args = SUPER::template args_from_tensor<Bias, ElementD>(bias);

    typename EVTCompute0::Arguments evt0_args{b_args};
    return ArgumentType{a_args, evt0_args, bias_args};
  }
};

/*
 * This epilogue directly supports per-tensor azp in int32 form.
 * As opposed to the per-token epilogue below, this epilogue only has an azp_adj
 * term, which should already be multiplied with the scalar azp.
 * The azp_adj term is a 1D tensor of shape (1,n), computed as azp * J @ B.
 *
 * This epilogue also supports bias, which remains per-channel.
 */
template <typename ElementAcc, typename ElementD, typename EpilogueDescriptor>
struct ScaledEpilogueBiasAzp
    : private ScaledEpilogueBase<ElementAcc, ElementD, EpilogueDescriptor> {
 private:
  using SUPER = ScaledEpilogueBase<ElementAcc, ElementD, EpilogueDescriptor>;
  using Accum = typename SUPER::Accum;
  using ScaleA = typename SUPER::template ColOrScalarLoad<float>;
  using ScaleB = typename SUPER::template RowOrScalarLoad<float>;
  using Bias = typename SUPER::template RowLoad<ElementD, true>;

  // This is the full AZP term, azp * J @ B, shape (1,n)
  using AzpWithAdj = typename SUPER::template RowLoad<int32_t>;

  // Compute float(accum - azp_adj), both operands are int32_t
  using ComputeAzp = cutlass::epilogue::fusion::Sm90Compute<
      cutlass::minus, float, int32_t,
      cutlass::FloatRoundStyle::round_to_nearest>;

  using EVTComputeAzp =
      cutlass::epilogue::fusion::Sm90EVT<ComputeAzp, Accum, AzpWithAdj>;

  using ComputeScaleB = cutlass::epilogue::fusion::Sm90Compute<
      cutlass::multiplies, float, float,
      cutlass::FloatRoundStyle::round_to_nearest>;

  using EVTComputeScaleB =
      cutlass::epilogue::fusion::Sm90EVT<ComputeScaleB, ScaleB, EVTComputeAzp>;

  using ComputeScaleBiasA = cutlass::epilogue::fusion::Sm90Compute<
      cutlass::multiply_add, ElementD, float,
      cutlass::FloatRoundStyle::round_to_nearest>;

 public:
  using EVTCompute =
      cutlass::epilogue::fusion::Sm90EVT<ComputeScaleBiasA, ScaleA,
                                         EVTComputeScaleB, Bias>;
  using ArgumentType = typename EVTCompute::Arguments;

  static ArgumentType prepare_args(torch::Tensor const& a_scales,
                                   torch::Tensor const& b_scales,
                                   torch::Tensor const& azp_adj,
                                   c10::optional<torch::Tensor> const& bias) {
    auto a_args = SUPER::template args_from_tensor<ScaleA, float>(a_scales);
    auto b_args = SUPER::template args_from_tensor<ScaleB, float>(b_scales);
    auto bias_args = SUPER::template args_from_tensor<Bias, ElementD>(bias);
    auto azp_adj_args =
        SUPER::template args_from_tensor<AzpWithAdj, int32_t>(azp_adj);

    typename EVTComputeAzp::Arguments evt_azp_args{{}, azp_adj_args};
    typename EVTComputeScaleB::Arguments evt_scale_b_args{b_args, evt_azp_args};
    return ArgumentType{a_args, evt_scale_b_args, bias_args};
  }
};

/*
 * This epilogue supports per-token azp by computing and applying
 * the correction term using a rank-1 update. If the term were materialized,
 * it would require O(m*n) space, and this way it only requires O(m+n) space.
 * The azp term is a 1D tensor of shape (m,1), and represents the unscaled zero
 * point for each row of A.
 * The azp_adj term is a 1D tensor of shape (1,n), computed as J @ B.
 *
 * This epilogue also supports bias, which remains per-channel.
 */
template <typename ElementAcc, typename ElementD, typename EpilogueDescriptor>
struct ScaledEpilogueBiasAzpToken
    : private ScaledEpilogueBase<ElementAcc, ElementD, EpilogueDescriptor> {
 private:
  using SUPER = ScaledEpilogueBase<ElementAcc, ElementD, EpilogueDescriptor>;
  using Accum = typename SUPER::Accum;
  using ScaleA = typename SUPER::template ColOrScalarLoad<float>;
  using ScaleB = typename SUPER::template RowOrScalarLoad<float>;
  using Bias = typename SUPER::template RowLoad<ElementD, true>;

  // Per-token azp term, shape (m,1)
  using Azp = typename SUPER::template ColLoad<int32_t>;

  // This is the AZP adjustment term, J @ B, shape (1,n)
  using AzpAdj = typename SUPER::template RowLoad<int32_t>;

  // Compute azp * azp_adj
  using ComputeAzp = cutlass::epilogue::fusion::Sm90Compute<
      cutlass::multiplies, int32_t, int32_t,
      cutlass::FloatRoundStyle::round_to_nearest>;

  using EVTComputeAzp =
      cutlass::epilogue::fusion::Sm90EVT<ComputeAzp, Azp, AzpAdj>;

  // Compute float(accum - azp*azp_adj), all operands are int32_t
  using ComputeAcc = cutlass::epilogue::fusion::Sm90Compute<
      cutlass::minus, float, int32_t,
      cutlass::FloatRoundStyle::round_to_nearest>;

  using EVTComputeAcc =
      cutlass::epilogue::fusion::Sm90EVT<ComputeAcc, Accum, EVTComputeAzp>;

  using ComputeScaleB = cutlass::epilogue::fusion::Sm90Compute<
      cutlass::multiplies, float, float,
      cutlass::FloatRoundStyle::round_to_nearest>;

  using EVTComputeScaleB =
      cutlass::epilogue::fusion::Sm90EVT<ComputeScaleB, ScaleB, EVTComputeAcc>;

  using ComputeScaleBiasA = cutlass::epilogue::fusion::Sm90Compute<
      cutlass::multiply_add, ElementD, float,
      cutlass::FloatRoundStyle::round_to_nearest>;

 public:
  using EVTCompute =
      cutlass::epilogue::fusion::Sm90EVT<ComputeScaleBiasA, ScaleA,
                                         EVTComputeScaleB, Bias>;
  using ArgumentType = typename EVTCompute::Arguments;

  static ArgumentType prepare_args(torch::Tensor const& a_scales,
                                   torch::Tensor const& b_scales,
                                   torch::Tensor const& azp_adj,
                                   torch::Tensor const& azp,
                                   c10::optional<torch::Tensor> const& bias) {
    auto a_args = SUPER::template args_from_tensor<ScaleA, float>(a_scales);
    auto b_args = SUPER::template args_from_tensor<ScaleB, float>(b_scales);
    auto bias_args = SUPER::template args_from_tensor<Bias, ElementD>(bias);
    auto azp_args = SUPER::template args_from_tensor<Azp, int32_t>(azp);
    auto azp_adj_args =
        SUPER::template args_from_tensor<AzpAdj, int32_t>(azp_adj);

    typename EVTComputeAzp::Arguments evt_azp_args{azp_args, azp_adj_args};
    typename EVTComputeAcc::Arguments evt_acc_args{{}, evt_azp_args};
    typename EVTComputeScaleB::Arguments evt_scale_b_args{b_args, evt_acc_args};
    return ArgumentType{a_args, evt_scale_b_args, bias_args};
  }
};

using GemmUniversalMode = cutlass::gemm::GemmUniversalMode;

template <typename ElementAB_, typename ElementD_,
          template <typename, typename, typename> typename Epilogue_,
          typename TileShape, typename ClusterShape, typename KernelSchedule,
          typename EpilogueSchedule, typename AccType,
          typename TileSchedule = cutlass::gemm::PersistentScheduler,
          GemmUniversalMode Mode_ = GemmUniversalMode::kGemm>
struct cutlass_3x_gemm {
  static const GemmUniversalMode Mode = Mode_;
  using ElementAB = ElementAB_;
  using ElementD = ElementD_;
  using ElementAcc = AccType;
      // typename std::conditional<std::is_same_v<ElementAB, int8_t>, int32_t,
      //                           float>::type;

  using EpilogueDescriptor =
      cutlass::epilogue::collective::detail::EpilogueDescriptor<
          TileShape, cutlass::epilogue::collective::EpilogueTileAuto, ElementD,
          ElementD, EpilogueSchedule>;

  using Epilogue = Epilogue_<ElementAcc, ElementD, EpilogueDescriptor>;

  using StrideD = Stride<int64_t, Int<1>, Int<0>>;
  using ElementC = void;
  using StrideC = StrideD;

  using EVTCompute = typename Epilogue::EVTCompute;

  using CollectiveEpilogue =
      typename cutlass::epilogue::collective::CollectiveBuilder<
          cutlass::arch::Sm90, cutlass::arch::OpClassTensorOp, TileShape,
          ClusterShape, cutlass::epilogue::collective::EpilogueTileAuto,
          ElementAcc, float, ElementC, StrideC, 4, ElementD, StrideD, 4,
          EpilogueSchedule, EVTCompute>::CollectiveOp;

  static constexpr size_t CEStorageSize =
      sizeof(typename CollectiveEpilogue::SharedStorage);
  using Stages = typename cutlass::gemm::collective::StageCountAutoCarveout<
      static_cast<int>(CEStorageSize)>;

  // clang-format off
  using CollectiveMainloop =
      typename cutlass::gemm::collective::CollectiveBuilder<
          cutlass::arch::Sm90, cutlass::arch::OpClassSparseTensorOp, 
          ElementAB, cutlass::layout::RowMajor, 32, 
          ElementAB, cutlass::layout::ColumnMajor, 16, 
          ElementAcc, TileShape, ClusterShape,
          Stages,
          KernelSchedule>::CollectiveOp;
  // clang-format on

  using KernelType = enable_sm90_or_later<cutlass::gemm::kernel::GemmUniversal<
      cute::Shape<int, int, int, int>, CollectiveMainloop, CollectiveEpilogue,
      TileSchedule>>;

  struct GemmKernel : public KernelType {};
};

template <typename Gemm, typename... EpilogueArgs>
void cutlass_sparse_gemm_caller(torch::Tensor& out, torch::Tensor const& a,
                         torch::Tensor const& e, torch::Tensor const& b,
                         EpilogueArgs&&... epilogue_params) {
  using ElementAB = typename Gemm::ElementAB;
  using ElementD = typename Gemm::ElementD;

  int32_t m = a.size(0);
  int32_t n = b.size(1);
  int32_t k = a.size(1);

  int64_t lda = a.stride(0);
  int64_t ldb = b.stride(1);
  int64_t ldc = out.stride(0);

  using StrideA = Stride<int64_t, Int<1>, int64_t>;
  using StrideB = Stride<int64_t, Int<1>, int64_t>;
  using StrideC = typename Gemm::StrideC;

  StrideA a_stride{lda, Int<1>{}, 0};
  StrideB b_stride{ldb, Int<1>{}, 0};
  StrideC c_stride{ldc, Int<1>{}, Int<0>{}};

  using GemmKernel = typename Gemm::GemmKernel;
  typename GemmKernel::ProblemShape prob_shape{m, n, k, 1};

  using LayoutA = typename GemmKernel::CollectiveMainloop::LayoutA;
  using LayoutE = typename GemmKernel::CollectiveMainloop::LayoutE;

  using ElementE = typename GemmKernel::CollectiveMainloop::ElementE;
  using SparseConfig = typename GemmKernel::CollectiveMainloop::SparseConfig;

  LayoutA a_layout = SparseConfig::fill_layoutA(prob_shape);
  LayoutE e_layout = SparseConfig::fill_layoutE(prob_shape);

  auto a_ptr = static_cast<ElementAB*>(a.data_ptr());
  auto b_ptr = static_cast<ElementAB*>(b.data_ptr());
  auto e_ptr = static_cast<ElementE*>(e.data_ptr());
  typename GemmKernel::MainloopArguments mainloop_args{a_ptr, a_layout,
                                                       b_ptr, b_stride,
                                                       e_ptr, e_layout};

  auto c_ptr = static_cast<ElementD*>(out.data_ptr());
  typename GemmKernel::EpilogueArguments epilogue_args{
      Gemm::Epilogue::prepare_args(
          std::forward<EpilogueArgs>(epilogue_params)...),
      c_ptr, c_stride, c_ptr, c_stride};

  typename GemmKernel::Arguments args{cutlass::gemm::GemmUniversalMode::kGemm,
                                      prob_shape, mainloop_args, epilogue_args};

  // Launch the CUTLASS GEMM kernel.
  using GemmOp = cutlass::gemm::device::GemmUniversalAdapter<GemmKernel>;
  GemmOp gemm_op;
  CUTLASS_CHECK(gemm_op.can_implement(args));

  size_t workspace_size = gemm_op.get_workspace_size(args);
  auto const workspace_options =
      torch::TensorOptions().dtype(torch::kUInt8).device(a.device());
  auto workspace = torch::empty(workspace_size, workspace_options);

  auto stream = at::cuda::getCurrentCUDAStream(a.get_device());

  cutlass::Status status = gemm_op.run(args, workspace.data_ptr(), stream);
  CUTLASS_CHECK(status);
}

template <typename InType, typename OutType,
          template <typename, typename, typename> typename Epilogue>
struct sm90_fp16_config_default {
  // M in (128, inf)
  static_assert(std::is_same<InType, cutlass::half_t>());
  using KernelSchedule =
      cutlass::gemm::KernelTmaWarpSpecializedPingpong;
  using EpilogueSchedule = typename cutlass::epilogue::TmaWarpSpecialized;
  using TileShape = Shape<_128, _128, _128>;
  using ClusterShape = Shape<_2, _1, _1>;
  using Cutlass3xGemm =
      cutlass_3x_gemm<InType, OutType, Epilogue, TileShape, ClusterShape,
                      KernelSchedule, EpilogueSchedule, float>;
};

template <typename InType, typename OutType,
          template <typename, typename, typename> typename Epilogue>
struct sm90_bf16_config_default {
  // M in (128, inf)
  static_assert(std::is_same<InType, cutlass::bfloat16_t>());
  using KernelSchedule =
      cutlass::gemm::KernelTmaWarpSpecializedPingpong;
  using EpilogueSchedule = typename cutlass::epilogue::TmaWarpSpecialized;
  using TileShape = Shape<_128, _128, _128>;
  using ClusterShape = Shape<_2, _1, _1>;
  using Cutlass3xGemm =
      cutlass_3x_gemm<InType, OutType, Epilogue, TileShape, ClusterShape,
                      KernelSchedule, EpilogueSchedule, float>;
};

template <typename InType, typename OutType,
          template <typename, typename, typename> typename Epilogue>
struct sm90_fp8_config_default {
  // M in (128, inf)
  static_assert(std::is_same<InType, cutlass::float_e4m3_t>());
  using KernelSchedule =
      cutlass::gemm::KernelTmaWarpSpecializedPingpongFP8FastAccum;
  using EpilogueSchedule = typename cutlass::epilogue::TmaWarpSpecialized;
  using TileShape = Shape<_128, _128, _128>;
  using ClusterShape = Shape<_2, _1, _1>;
  using Cutlass3xGemm =
      cutlass_3x_gemm<InType, OutType, Epilogue, TileShape, ClusterShape,
                      KernelSchedule, EpilogueSchedule, float>;
};

template <typename InType, typename OutType,
          template <typename, typename, typename> typename Epilogue>
struct sm90_fp8_config_M64 {
  // M in [1, 64]
  static_assert(std::is_same<InType, cutlass::float_e4m3_t>());
  using KernelSchedule =
      cutlass::gemm::KernelTmaWarpSpecializedPingpongFP8FastAccum;
  using EpilogueSchedule = typename cutlass::epilogue::TmaWarpSpecializedCooperative;
  using TileShape = Shape<_64, _64, _256>;
  using ClusterShape = Shape<_1, _1, _1>;

  using TileSchedule = cutlass::gemm::PersistentScheduler;

  using Cutlass3xGemm =
      cutlass_3x_gemm<InType, OutType, Epilogue, TileShape, ClusterShape,
                      KernelSchedule, EpilogueSchedule, float,
                      TileSchedule>;
};

template <typename InType, typename OutType,
          template <typename, typename, typename> typename Epilogue>
struct sm90_fp8_config_M128 {
  // M in (64, 128]
  static_assert(std::is_same<InType, cutlass::float_e4m3_t>());
  using KernelSchedule =
      cutlass::gemm::KernelTmaWarpSpecializedCooperativeFP8FastAccum;
  using EpilogueSchedule = typename cutlass::epilogue::TmaWarpSpecializedCooperative;
  using TileShape = Shape<_128, _64, _256>;
  using ClusterShape = Shape<_1, _1, _1>;

  using TileSchedule = cutlass::gemm::PersistentScheduler;

  using Cutlass3xGemm =
      cutlass_3x_gemm<InType, OutType, Epilogue, TileShape, ClusterShape,
                      KernelSchedule, EpilogueSchedule, float,
                      TileSchedule>;
};

template <typename InType, typename OutType,
          template <typename, typename, typename> typename Epilogue>
struct sm90_fp8_config_M256 {
  // M in (128, 256]
  static_assert(std::is_same<InType, cutlass::float_e4m3_t>());
  using KernelSchedule =
      cutlass::gemm::KernelTmaWarpSpecializedCooperativeFP8FastAccum;
  using EpilogueSchedule = typename cutlass::epilogue::TmaWarpSpecializedCooperative;
  using TileShape = Shape<_128, _128, _256>;
  using ClusterShape = Shape<_1, _1, _1>;

  using TileSchedule = cutlass::gemm::PersistentScheduler;

  using Cutlass3xGemm =
      cutlass_3x_gemm<InType, OutType, Epilogue, TileShape, ClusterShape,
                      KernelSchedule, EpilogueSchedule, float,
                      TileSchedule>;
};

template <typename InType, typename OutType,
          template <typename, typename, typename> typename Epilogue>
struct sm90_fp8_config_M512 {
  // M in (256, ]
  static_assert(std::is_same<InType, cutlass::float_e4m3_t>());
  using KernelSchedule =
      cutlass::gemm::KernelTmaWarpSpecializedPingpongFP8FastAccum;
  using EpilogueSchedule = typename cutlass::epilogue::TmaWarpSpecializedCooperative;
  using TileShape = Shape<_256, _128, _128>;
  using ClusterShape = Shape<_1, _1, _1>;

  using TileSchedule = cutlass::gemm::PersistentScheduler;

  using Cutlass3xGemm =
      cutlass_3x_gemm<InType, OutType, Epilogue, TileShape, ClusterShape,
                      KernelSchedule, EpilogueSchedule, float,
                      TileSchedule>;
};

template <typename InType, typename OutType,
          template <typename, typename, typename> typename Epilogue>
struct sm90_int8_config_default {
  // For M > 128 and any N
  static_assert(std::is_same<InType, int8_t>());
  using KernelSchedule =
      typename cutlass::gemm::KernelTmaWarpSpecializedPingpong;
  using EpilogueSchedule = typename cutlass::epilogue::TmaWarpSpecialized;
  using TileShape = Shape<_128, _128, _128>;
  using ClusterShape = Shape<_2, _1, _1>;
  using Cutlass3xGemm =
      cutlass_3x_gemm<InType, OutType, Epilogue, TileShape, ClusterShape,
                      KernelSchedule, EpilogueSchedule, int32_t>;
};

template <typename InType, typename OutType,
          template <typename, typename, typename> typename Epilogue>
struct sm90_int8_config_M128 {
  // For M in (64, 128] and any N
  static_assert(std::is_same<InType, int8_t>());
  using KernelSchedule =
      typename cutlass::gemm::KernelTmaWarpSpecializedPingpong;
  using EpilogueSchedule = typename cutlass::epilogue::TmaWarpSpecialized;
  using TileShape = Shape<_64, _128, _128>;
  using ClusterShape = Shape<_2, _1, _1>;
  using Cutlass3xGemm =
      cutlass_3x_gemm<InType, OutType, Epilogue, TileShape, ClusterShape,
                      KernelSchedule, EpilogueSchedule, int32_t>;
};

template <typename InType, typename OutType,
          template <typename, typename, typename> typename Epilogue>
struct sm90_int8_config_M64 {
  // For M in (32, 64] and any N
  static_assert(std::is_same<InType, int8_t>());
  using KernelSchedule = typename cutlass::gemm::KernelTmaWarpSpecialized;
  using EpilogueSchedule = typename cutlass::epilogue::TmaWarpSpecialized;
  using TileShape = Shape<_64, _64, _256>;
  using ClusterShape = Shape<_1, _1, _1>;
  using Cutlass3xGemm =
      cutlass_3x_gemm<InType, OutType, Epilogue, TileShape, ClusterShape,
                      KernelSchedule, EpilogueSchedule, int32_t>;
};

template <typename InType, typename OutType,
          template <typename, typename, typename> typename Epilogue>
struct sm90_int8_config_M32_NBig {
  // For M in [1, 32] and N >= 8192
  static_assert(std::is_same<InType, int8_t>());
  using KernelSchedule = typename cutlass::gemm::KernelTmaWarpSpecialized;
  using EpilogueSchedule = typename cutlass::epilogue::TmaWarpSpecialized;
  using TileShape = Shape<_64, _128, _256>;
  using ClusterShape = Shape<_1, _4, _1>;
  using Cutlass3xGemm =
      cutlass_3x_gemm<InType, OutType, Epilogue, TileShape, ClusterShape,
                      KernelSchedule, EpilogueSchedule, int32_t>;
};

template <typename InType, typename OutType,
          template <typename, typename, typename> typename Epilogue>
struct sm90_int8_config_M32_NSmall {
  // For M in [1, 32] and N < 8192
  static_assert(std::is_same<InType, int8_t>());
  using KernelSchedule = typename cutlass::gemm::KernelTmaWarpSpecialized;
  using EpilogueSchedule = typename cutlass::epilogue::TmaWarpSpecialized;
  using TileShape = Shape<_64, _64, _256>;
  using ClusterShape = Shape<_1, _8, _1>;
  using Cutlass3xGemm =
      cutlass_3x_gemm<InType, OutType, Epilogue, TileShape, ClusterShape,
                      KernelSchedule, EpilogueSchedule, int32_t>;
};

}  // namespace