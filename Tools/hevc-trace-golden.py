# Reads ffmpeg trace_headers output on stdin; prints JSON: the SPS/PPS fields and, per slice
# segment in decode order, the header fields VideoHEVCTests compares.
import json, re, sys
line_re = re.compile(r"^\[trace_headers @ [^\]]+\] (\d+)\s+(\S+)\s+[01]+ = (-?\d+)")
units, cur = [], None
for line in sys.stdin:
    head = re.match(r"^\[trace_headers @ [^\]]+\] ([A-Za-z][A-Za-z ()/-]+)$", line.rstrip())
    if head:
        # Every heading (parameter sets, slice headers, SEI, AUD…) starts a new unit.
        cur = {"kind": head.group(1).strip(), "fields": {}}
        units.append(cur)
        continue
    m = line_re.match(line)
    if m and cur is not None:
        pos, name, value = int(m.group(1)), m.group(2), int(m.group(3))
        f = cur["fields"]
        if name in f:
            if not isinstance(f[name], list): f[name] = [f[name]]
            f[name].append(value)
        else:
            f[name] = value
        if name == "alignment_bit_equal_to_one": cur["alignment_pos"] = pos
keep = {"Sequence Parameter Set": ["pic_width_in_luma_samples", "pic_height_in_luma_samples", "bit_depth_luma_minus8", "log2_max_pic_order_cnt_lsb_minus4",
                                   "log2_min_luma_coding_block_size_minus3", "log2_diff_max_min_luma_coding_block_size", "num_short_term_ref_pic_sets",
                                   "sample_adaptive_offset_enabled_flag", "amp_enabled_flag", "scaling_list_enabled_flag", "sps_temporal_mvp_enabled_flag"],
        "Picture Parameter Set": ["init_qp_minus26", "tiles_enabled_flag", "entropy_coding_sync_enabled_flag", "sign_data_hiding_enabled_flag",
                                  "cu_qp_delta_enabled_flag", "weighted_pred_flag", "weighted_bipred_flag", "transform_skip_enabled_flag"],
        "Slice Segment Header": ["nal_unit_type", "slice_type", "slice_pic_order_cnt_lsb", "slice_qp_delta", "num_entry_point_offsets",
                                 "num_ref_idx_l0_active_minus1", "num_ref_idx_l1_active_minus1", "five_minus_max_num_merge_cand",
                                 "collocated_ref_idx", "slice_sao_luma_flag", "slice_temporal_mvp_enabled_flag", "luma_log2_weight_denom"]}
out = {"sps": [], "pps": [], "slices": []}
for u in units:
    if u["kind"] not in keep: continue
    d = {k: u["fields"][k] for k in keep[u["kind"]] if k in u["fields"]}
    if u["kind"] == "Slice Segment Header":
        if "alignment_pos" in u: d["data_offset_bits_at_least"] = u["alignment_pos"]
        out["slices"].append(d)
    else:
        out["sps" if u["kind"].startswith("Seq") else "pps"].append(d)
json.dump(out, sys.stdout, indent=0, sort_keys=True)
