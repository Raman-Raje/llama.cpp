// TileK-first layout for activations feeding Adreno Matrix ALU coopmat
// matmuls. A row-major nrows x K tensor stores element (row, kidx) at
//   TILEK * ((kidx / TILEK) * nrows + row) + kidx % TILEK
// so each nrows x TILEK tile is one contiguous block. Producers (the *_qcom
// elementwise shaders) write this layout; the B_TILEK_FIRST matmul loader
// reads it. Requires K % TILEK == 0, a contiguous tensor with zero misalign
// offset and a single batch.

const uint TILEK = 16;

// Index of element (row, kidx) of an nrows x K tensor in TileK-first order.
uint tilek_first_idx(const uint row, const uint kidx, const uint nrows) {
   return TILEK * ((kidx / TILEK) * nrows + row) + kidx % TILEK;
}

// Remap a linear row-major index (row * k + kidx) to TileK-first.
// Valid only when k % TILEK == 0.
uint tilek_first_from_linear(const uint idx, const uint k, const uint nrows) {
   return tilek_first_idx(idx / k, idx % k, nrows);
}