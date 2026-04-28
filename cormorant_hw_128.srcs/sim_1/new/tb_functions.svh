// tb_functions.svh — shared reference arithmetic for cormorant_tb.
//
// ap_fixed<16,8> encoding:  real_value = raw_int16 / 256.0
//
// VectorOP reference (element-wise, integer arithmetic):
//   ADD/SUB  clip(a ± b,           −32768, +32767)
//   MUL      clip((a × b) >>> 8,   −32768, +32767)
//   DIV      clip(truncate_to_zero(a<<8 / b), −32768, +32767)   (AP_TRN_ZERO)
//   RELU     max(a, 0)
//   RELU6    clip(max(a, 0), 0, 0x0600)
//
// ConvKernel reference (constant-fill, no padding):
//   acc = n_active × x_raw × w_raw  [+ b_raw×256 if bias]
//   y_raw = clip(acc >>> 8, −32768, +32767)
//
// MatmulKernel reference (constant-fill):
//   c_raw = clip(K × a_raw × b_raw >>> 8, −32768, +32767)
//
// PoolingKernel reference (constant-fill, no padding):
//   MaxPool / AvgPool:  y_float = x_float
//   LpPool p=1, N:      y_float = N × |x_float|
//   LpPool p=2, N:      y_float = sqrt(N) × |x_float|
//   y_raw = clip(floor(y_float × 256), −32768, +32767)

// -----------------------------------------------------------------------
// Utility
// -----------------------------------------------------------------------
function automatic int unsigned align_up(int unsigned n, int unsigned align_);
    return (n + align_ - 1) & ~(align_ - 1);
endfunction

// -----------------------------------------------------------------------
// VectorOP element-wise reference functions
// -----------------------------------------------------------------------
function automatic logic [15:0] ref_add(logic [15:0] a, b);
    longint signed s = longint'(signed'(a)) + longint'(signed'(b));
    if (s >  32767) s =  32767;
    if (s < -32768) s = -32768;
    return s[15:0];
endfunction

function automatic logic [15:0] ref_sub(logic [15:0] a, b);
    longint signed s = longint'(signed'(a)) - longint'(signed'(b));
    if (s >  32767) s =  32767;
    if (s < -32768) s = -32768;
    return s[15:0];
endfunction

function automatic logic [15:0] ref_mul(logic [15:0] a, b);
    longint signed p = longint'(signed'(a)) * longint'(signed'(b));
    p = p >>> 8;
    if (p >  32767) p =  32767;
    if (p < -32768) p = -32768;
    return p[15:0];
endfunction

function automatic logic [15:0] ref_div(logic [15:0] a, b);
    longint signed q = (longint'(signed'(a)) <<< 8) / longint'(signed'(b));
    if (q >  32767) q =  32767;
    if (q < -32768) q = -32768;
    return q[15:0];
endfunction

function automatic logic [15:0] ref_relu(logic [15:0] a);
    return ($signed(a) < 0) ? 16'h0000 : a;
endfunction

function automatic logic [15:0] ref_relu6(logic [15:0] a);
    if ($signed(a) < 0)         return 16'h0000;
    if ($signed(a) > 16'sh0600) return 16'h0600;
    return a;
endfunction

// Softmax reference — uniform-input row: all elements equal → output = 1/size.
// Matches HW: exp(a[i]-max)*inv_sum = exp(0)*1/size = 1/size, AP_TRN cast.
// Only valid when every element in the row is the same value (input cancels).
function automatic logic [15:0] ref_softmax_uniform(int unsigned size_);
    real          f;
    longint signed y;
    f = 1.0 / $itor(size_);
    y = longint'($floor(f * 256.0));
    if (y >  32767) y =  32767;
    if (y < -32768) y = -32768;
    return y[15:0];
endfunction

// Dispatch expected value for one (a, b) pair given op code.
function automatic logic [15:0] compute_ref(
    logic [31:0] op,
    logic [15:0] a,
    logic [15:0] b
);
    case (op)
        OP_ADD:   return ref_add(a, b);
        OP_SUB:   return ref_sub(a, b);
        OP_MUL:   return ref_mul(a, b);
        OP_DIV:   return ref_div(a, b);
        OP_RELU:  return ref_relu(a);
        OP_RELU6: return ref_relu6(a);
        default:  return 16'hXXXX;
    endcase
endfunction

// -----------------------------------------------------------------------
// ConvKernel reference (constant-fill input and weights, no padding)
// -----------------------------------------------------------------------
function automatic logic [15:0] compute_conv_const(
    logic [15:0] x_raw,
    logic [15:0] w_raw,
    int unsigned n_active,
    logic [15:0] b_raw,
    logic        use_bias);
    longint signed acc;
    acc = longint'(signed'(x_raw)) * longint'(signed'(w_raw));
    acc = acc * longint'(int'(n_active));
    if (use_bias)
        acc = acc + longint'(signed'(b_raw)) * 256;
    acc = acc >>> 8;
    if (acc >  longint'(32767))  acc =  longint'(32767);
    if (acc < -longint'(32768))  acc = -longint'(32768);
    return acc[15:0];
endfunction

// -----------------------------------------------------------------------
// MatmulKernel reference (constant-fill A and B)
// -----------------------------------------------------------------------
function automatic logic [15:0] compute_mm_const(
    logic [15:0] a_raw, logic [15:0] b_raw, int unsigned k);
    longint signed acc;
    acc = longint'(signed'(a_raw)) * longint'(signed'(b_raw));
    acc = acc * longint'(int'(k));
    acc = acc >>> 8;
    if (acc >  longint'(32767))  acc =  longint'(32767);
    if (acc < -longint'(32768))  acc = -longint'(32768);
    return acc[15:0];
endfunction

// -----------------------------------------------------------------------
// DDR constant fill — write nbytes of a repeated 16-bit val starting at base.
// Requires CHUNK_BYTES, CHUNK_BITS localparams and the `PS macro.
// -----------------------------------------------------------------------
task automatic fill_const_ddr(input [39:0]      base,
                               input int unsigned nbytes,
                               input logic [15:0] val);
    logic [CHUNK_BITS-1:0] buf_mem;
    int unsigned i, n_chunks, rem;
    for (i = 0; i < CHUNK_BYTES / 2; i++)
        buf_mem[i*16 +: 16] = val;
    n_chunks = nbytes / CHUNK_BYTES;
    rem      = nbytes % CHUNK_BYTES;
    for (i = 0; i < n_chunks; i++)
        `PS.write_mem(buf_mem, base + 40'(i * CHUNK_BYTES), CHUNK_BYTES);
    if (rem > 0)
        `PS.write_mem(buf_mem, base + 40'(n_chunks * CHUNK_BYTES), rem);
endtask

// -----------------------------------------------------------------------
// PoolingKernel reference (constant-fill input, no padding)
// -----------------------------------------------------------------------
function automatic logic [15:0] compute_pool_const(
    logic [15:0] x_raw,
    int unsigned n,
    int unsigned pool_type,
    int unsigned lp_order);
    real x_float, y_float;
    longint signed y_int;
    x_float = $itor($signed(x_raw)) / 256.0;
    if (pool_type == 0) begin          // MaxPool: max of N identical = x
        y_float = x_float;
    end else if (pool_type == 1) begin // AvgPool: sum/N = x
        y_float = x_float;
    end else begin                     // LpPool
        if (lp_order == 1)
            y_float = n * (x_float >= 0.0 ? x_float : -x_float);
        else
            y_float = $sqrt(1.0 * n) * (x_float >= 0.0 ? x_float : -x_float);
    end
    y_int = longint'($floor(y_float * 256.0));
    if (y_int >  32767) y_int =  32767;
    if (y_int < -32768) y_int = -32768;
    return y_int[15:0];
endfunction
