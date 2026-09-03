import importlib.util
import os
import sys
import unittest

# Load this repo's tools/netasm package by explicit file path rather
# than via `import tools.netasm`: some environments put an unrelated
# `tools` namespace package earlier on PYTHONPATH (e.g. Project
# Trellis's own tools/ directory), which would otherwise shadow this
# repo's tools/ and break the dotted import regardless of sys.path
# ordering tricks.
_PKG_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
_spec = importlib.util.spec_from_file_location(
    "netasm_under_test", os.path.join(_PKG_DIR, "__init__.py"),
    submodule_search_locations=[_PKG_DIR],
)
_netasm = importlib.util.module_from_spec(_spec)
sys.modules["netasm_under_test"] = _netasm
_spec.loader.exec_module(_netasm)

parse = _netasm.parse
NetasmSyntaxError = _netasm.NetasmSyntaxError
GraphNet = _netasm.GraphNet
DenseNet = _netasm.DenseNet
assemble_graph = _netasm.assemble_graph
assemble_dense = _netasm.assemble_dense
NetasmError = _netasm.NetasmError
F = importlib.import_module("netasm_under_test.frames")

# The worked example from spec §3 / already validated byte-exact in
# sim/graph_format_tb.v and end-to-end in sim/graph_engine_tb.v and
# sim/spi_neuron_top_graph_tb.v: 4 inputs, n4 = relu(x0*5+x1*(-3)+2),
# n5 = x2*7 + act[n4]*2, output = n5.
GRAPH_SRC = """
; worked example, spec §3
NET graph
INPUTS 4
NEURON n4 relu bias=2
  CONN 0 w=5
  CONN 1 w=-3
NEURON n5 none bias=0
  CONN n4 w=2
  CONN 2 w=7
OUTPUT n5
END
"""


class TestParser(unittest.TestCase):
    def test_parses_graph(self):
        net = parse(GRAPH_SRC)
        self.assertIsInstance(net, GraphNet)
        self.assertEqual(net.n_inputs, 4)
        self.assertEqual([n.name for n in net.neurons], ["n4", "n5"])
        self.assertEqual(net.outputs, ["n5"])

    def test_parses_dense(self):
        src = """
        NET dense
        INPUTS 256
        LAYER 64 relu
        LAYER 16 relu
        LAYER 4 none
        END
        """
        net = parse(src)
        self.assertIsInstance(net, DenseNet)
        self.assertEqual(net.n_inputs, 256)
        self.assertEqual([l.n_neurons for l in net.layers], [64, 16, 4])
        self.assertEqual([l.activation for l in net.layers], ["relu", "relu", "none"])

    def test_missing_net_directive(self):
        with self.assertRaises(NetasmSyntaxError):
            parse("INPUTS 4\nEND\n")

    def test_missing_end(self):
        with self.assertRaises(NetasmSyntaxError):
            parse("NET graph\nINPUTS 4\nNEURON n0 relu bias=0\n  CONN 0 w=1\nOUTPUT n0\n")

    def test_conn_outside_neuron(self):
        with self.assertRaises(NetasmSyntaxError):
            parse("NET graph\nINPUTS 4\nCONN 0 w=1\nEND\n")

    def test_bad_weight_range(self):
        with self.assertRaises(NetasmSyntaxError):
            parse(
                "NET graph\nINPUTS 4\nNEURON n0 relu bias=0\n  CONN 0 w=200\n"
                "OUTPUT n0\nEND\n"
            )

    def test_comments_and_blank_lines_ignored(self):
        src = "; comment\nNET graph\n\nINPUTS 4 ; trailing comment\n" \
              "NEURON n0 relu bias=0\n  CONN 0 w=1\nOUTPUT n0\nEND\n"
        net = parse(src)
        self.assertEqual(net.n_inputs, 4)


class TestGraphAssembler(unittest.TestCase):
    def setUp(self):
        self.net = parse(GRAPH_SRC)

    def test_id_assignment(self):
        layout = assemble_graph(self.net, parallel=2)
        self.assertEqual(layout.id_of["n4"], 4)
        self.assertEqual(layout.id_of["n5"], 5)
        self.assertEqual(layout.num_neurons, 2)
        self.assertEqual(layout.n_out, 1)
        self.assertEqual(layout.n_total, 6)  # 4 inputs + 2 neurons

    def test_byte_exact_descriptor_and_edges_no_padding(self):
        # PARALLEL=2, n_conn=2 for both neurons -> n_conn_padded=2,
        # i.e. no padding edges at all: exactly matches the byte
        # layout hand-verified in sim/graph_format_tb.v.
        layout = assemble_graph(
            self.net, parallel=2, table_base=0x000000, edges_base=0x000100
        )

        n4_edges_addr = 0x000100
        n5_edges_addr = 0x000100 + 8  # n4 has exactly 2 edges, 4 bytes each, no padding

        expected_desc = bytes([
            # n4: conn_ptr, n_conn=2, out_id=4, act=RELU(1), bias=2, reserved
            (n4_edges_addr >> 16) & 0xFF, (n4_edges_addr >> 8) & 0xFF, n4_edges_addr & 0xFF,
            0x00, 0x02,
            0x00, 0x04,
            0x01,
            0x02,
            0x00, 0x00,
            # n5: conn_ptr, n_conn=2, out_id=5, act=NONE(0), bias=0, reserved
            (n5_edges_addr >> 16) & 0xFF, (n5_edges_addr >> 8) & 0xFF, n5_edges_addr & 0xFF,
            0x00, 0x02,
            0x00, 0x05,
            0x00,
            0x00,
            0x00, 0x00,
        ])
        self.assertEqual(layout.descriptor_bytes, expected_desc)

        expected_n4_edges = bytes([
            0x00, 0x00, 0x05, 0x00,        # src=0, w=5
            0x00, 0x01, (-3) & 0xFF, 0x00,  # src=1, w=-3
        ])
        expected_n5_edges = bytes([
            0x00, 0x04, 0x02, 0x00,  # src=4 (n4), w=2
            0x00, 0x02, 0x07, 0x00,  # src=2, w=7
        ])
        self.assertEqual(layout.edge_bytes["n4"], expected_n4_edges)
        self.assertEqual(layout.edge_bytes["n5"], expected_n5_edges)

    def test_parallel_padding(self):
        # Same graph, PARALLEL=4 -> n_conn=2 pads to 4 (2 extra
        # zero-weight, src=0 edges per neuron), as exercised end to
        # end in sim/graph_engine_tb.v.
        layout = assemble_graph(self.net, parallel=4, max_conn=8)
        self.assertEqual(layout.n_conn_padded["n4"], 4)
        self.assertEqual(layout.n_conn_padded["n5"], 4)
        self.assertEqual(len(layout.edge_bytes["n4"]), 16)
        # padding tail is (src=0, w=0, reserved=0)
        self.assertEqual(layout.edge_bytes["n4"][8:], bytes(8))
        self.assertEqual(layout.edge_bytes["n5"][8:], bytes(8))
        # descriptor's n_conn is the REAL count, not padded (§4.2)
        self.assertEqual(layout.descriptor_bytes[3:5], bytes([0x00, 0x02]))

    def test_zero_conn_neuron_still_pads_to_one_group(self):
        src = (
            "NET graph\nINPUTS 2\n"
            "NEURON n2 none bias=5\nOUTPUT n2\nEND\n"
        )
        net = parse(src)
        layout = assemble_graph(net, parallel=4, max_conn=8)
        self.assertEqual(layout.n_conn_padded["n2"], 4)

    def test_frames_sequence(self):
        layout = assemble_graph(self.net, parallel=2)
        labels = [fr.label.split("(")[0] for fr in layout.frames]
        self.assertEqual(
            labels,
            [
                "WRITE_RAM",  # table
                "WRITE_RAM",  # n4 edges
                "WRITE_RAM",  # n5 edges
                "SET_NET_TYPE",
                "SET_BASE",  # x_base
                "SET_BASE",  # table_base
                "SET_BASE",  # out_base (buf_a_base)
                "SET_BASE",  # n_inputs_real (N_in)
                "SET_BASE",  # num_neurons_graph
                "SET_BASE",  # n_out
                "RUN_NETWORK",
            ],
        )
        run_frame = layout.frames[-1]
        self.assertEqual(run_frame.data[0], F.OP_RUN_NETWORK)

    # ---- compile-time guard tests (mirrors sim/graph_engine_guard_tb.v) ----

    def test_self_reference_rejected(self):
        # n1 references itself; n2 (not n1) is the actual OUTPUT, so
        # this isolates the src_id < out_id check from the separate
        # "output used as source" check below.
        src = (
            "NET graph\nINPUTS 1\n"
            "NEURON n1 relu bias=0\n  CONN n1 w=1\n"
            "NEURON n2 relu bias=0\n  CONN 0 w=1\n"
            "OUTPUT n2\nEND\n"
        )
        net = parse(src)
        with self.assertRaisesRegex(NetasmError, "not a strictly earlier signal"):
            assemble_graph(net, parallel=2)

    def test_forward_reference_rejected(self):
        # n1 references n2, declared AFTER it; n3 (not n2) is the
        # actual OUTPUT, so n2 is an ordinary (non-output) neuron and
        # this isolates the src_id < out_id check from "output used
        # as source" below.
        src = (
            "NET graph\nINPUTS 1\n"
            "NEURON n1 relu bias=0\n  CONN n2 w=1\n"
            "NEURON n2 relu bias=0\n  CONN 0 w=1\n"
            "NEURON n3 relu bias=0\n  CONN n1 w=1\n"
            "OUTPUT n3\nEND\n"
        )
        net = parse(src)
        with self.assertRaisesRegex(NetasmError, "not a strictly earlier signal"):
            assemble_graph(net, parallel=2)

    def test_output_used_as_source_rejected(self):
        src = (
            "NET graph\nINPUTS 2\n"
            "NEURON n2 relu bias=0\n  CONN 0 w=1\n"
            "NEURON n3 relu bias=0\n  CONN n2 w=1\n"
            "OUTPUT n2\nOUTPUT n3\nEND\n"
        )
        net = parse(src)
        with self.assertRaisesRegex(NetasmError, "used as a source"):
            assemble_graph(net, parallel=2)

    def test_max_conn_overflow_rejected(self):
        conns = "\n".join(f"  CONN 0 w=1" for _ in range(10))
        src = f"NET graph\nINPUTS 1\nNEURON n1 relu bias=0\n{conns}\nOUTPUT n1\nEND\n"
        net = parse(src)
        with self.assertRaisesRegex(NetasmError, "MAX_CONN"):
            assemble_graph(net, parallel=4, max_conn=8)  # 10 conns pad to 12 > 8

    def test_n_total_overflow_rejected(self):
        layout_ok = assemble_graph(self.net, parallel=2, n_total=6)  # exactly fits
        self.assertEqual(layout_ok.n_total, 6)
        with self.assertRaisesRegex(NetasmError, "N_TOTAL"):
            assemble_graph(self.net, parallel=2, n_total=5)

    def test_undeclared_output_rejected(self):
        src = "NET graph\nINPUTS 1\nNEURON n1 relu bias=0\n  CONN 0 w=1\nOUTPUT ghost\nEND\n"
        net = parse(src)
        with self.assertRaisesRegex(NetasmError, "undeclared"):
            assemble_graph(net, parallel=2)


class TestDenseAssembler(unittest.TestCase):
    def test_layout_and_descriptor(self):
        src = "NET dense\nINPUTS 8\nLAYER 4 relu\nLAYER 2 none\nEND\n"
        net = parse(src)
        layout = assemble_dense(net, parallel=4, table_base=0, weights_base=0x1000)

        self.assertEqual(layout.layers[0].n_inputs_real, 8)
        self.assertEqual(layout.layers[0].n_neurons_real, 4)
        self.assertEqual(layout.layers[1].n_inputs_real, 4)
        self.assertEqual(layout.layers[1].n_neurons_real, 2)

        # layer0: w_base at weights_base, 8*4=32 bytes, then bias 4 bytes
        self.assertEqual(layout.layers[0].w_base, 0x1000)
        self.assertEqual(layout.layers[0].bias_addr, 0x1000 + 32)
        # layer1 follows immediately after layer0's bias region
        self.assertEqual(layout.layers[1].w_base, 0x1000 + 32 + 4)

        self.assertEqual(len(layout.descriptor_bytes), 11 * 2)

    def test_non_multiple_of_parallel_rejected(self):
        src = "NET dense\nINPUTS 6\nLAYER 4 relu\nEND\n"  # 6 not a multiple of 4
        net = parse(src)
        with self.assertRaisesRegex(NetasmError, "PARALLEL"):
            assemble_dense(net, parallel=4)


if __name__ == "__main__":
    unittest.main()
