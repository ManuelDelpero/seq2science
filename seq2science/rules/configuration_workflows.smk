"""
all rules/logic related to differential gene expression with deseq2 should be here.
"""

import math
import os
import hashlib

import pandas as pd

from seq2science.util import parse_contrast


# apply workflow specific changes...
# ...for atac-seq
if config.get("peak_caller", False):
    config["peak_caller"] = {k: v for k, v in config["peak_caller"].items()}

    # if genrich is peak caller, make sure to not double shift reads
    if "genrich" in config["peak_caller"]:
        # always turn of genrich shift, since we handle that with deeptools
        if "-j" in config["peak_caller"]["genrich"] and not "-D" in config["peak_caller"]["genrich"]:
            config["peak_caller"]["genrich"] += " -D"

    # if hmmratac peak caller, check if all samples are paired-end
    if "hmmratac" in config["peak_caller"]:
        assert all(
            [sampledict[sample]["layout"] == "PAIRED" for sample in samples.index]
        ), "HMMRATAC requires all samples to be paired end"

    config["macs2_types"] = ["control_lambda.bdg", "peaks.xls", "treat_pileup.bdg"]
    if "macs2" in config["peak_caller"]:
        params = config["peak_caller"]["macs2"].split(" ")
        invalid_params = [
            "-t",
            "--treatment",
            "-c",
            "--control",
            "-n",
            "--name",
            "--outdir",
            "-f",
            "--format",
            "-g",
            "--gsize",
            "-p",
            "--pvalue",
        ]
        assert not any(val in params for val in invalid_params), (
            f"You filled in a parameter for macs2 which the "
            f"pipeline does not support. Unsupported params are:"
            f"{invalid_params}."
        )

        config["macs_cmbreps"] = ""
        cmbreps_params = ["-q", "--qvalue", "--min-length", "--max-gap", "--broad-cutoff"]
        for param in cmbreps_params:
            if param in params:
                idx = params.index(param) + 1
                if param == "-q" or param == "--qvalue":
                    val = -math.log(float(params[idx]), 10)
                    config["macs_cmbreps"] += f" -c {val} "
                else:
                    config["macs_cmbreps"] += f" {param} {params[idx]} "

        if "--broad" in config["peak_caller"]["macs2"]:
            config["macs2_types"].extend(["peaks.broadPeak", "peaks.gappedPeak"])
        else:
            config["macs2_types"].extend(["summits.bed", "peaks.narrowPeak"])

# make sure that both maximum and minimum insert sizes are existing when one of them is used
if config.get("min_template_length") and not config.get("max_template_length"):
    config["max_template_length"] = 1_000_000_000

if config.get("max_template_length") and not config.get("min_template_length"):
    config["min_template_length"] = 0

config["filter_on_size"] = filter_size = bool(config.get("min_template_length") or config.get("max_template_length"))


# ...for alignment and rna-seq
for conf_dict in ["aligner", "quantifier", "tpm2counts", "trimmer"]:
    if config.get(conf_dict, False):
        dict_key = list(config[conf_dict].keys())[0]
        for k, v in list(config[conf_dict].values())[0].items():
            config[k] = v
        config[conf_dict] = dict_key


# ...for rna-seq
if get_workflow() == "rna_seq":
    assert config["aligner"] in [
        "star",
        "hisat2",
    ], f"\nPlease select a splice aware aligner for the RNA-seq (STAR or HISAT2)\n"

    # regular dict is prettier in the log
    config["deseq2"] = dict(config["deseq2"])


# ...for alignment
if config.get("bam_sorter", False):
    config["bam_sort_order"] = list(config["bam_sorter"].values())[0]
    config["bam_sorter"] = list(config["bam_sorter"].keys())[0]


# ...for scrna quantification
if get_workflow() == "scrna_seq":
    if config["quantifier"] not in ["kallistobus", "citeseqcount"]:
        logger.error(
            f"Invalid quantifier selected" "Please select a supported scrna quantifier (kallistobus or citeseqcount)!"
        )
        sys.exit(1)


# make sure that our samples.tsv and configuration work together...
# ...on biological replicates
if "biological_replicates" in samples:
    if "peak_caller" in config and "hmmratac" in config.get("peak_caller"):
        assert config.get("biological_replicates", "") in [
            "idr",
            "keep",
        ], f"HMMRATAC peaks can only be combined through idr"

    for condition in set(samples["biological_replicates"]):
        for assembly in set(samples[samples["biological_replicates"] == condition]["assembly"]):
            if "technical_replicates" in samples:
                nr_samples = len(
                    set(
                        samples[(samples["biological_replicates"] == condition) & (samples["assembly"] == assembly)][
                            "technical_replicates"
                        ]
                    )
                )
            else:
                nr_samples = len(
                    samples[(samples["biological_replicates"] == condition) & (samples["assembly"] == assembly)]
                )

            if config.get("biological_replicates", "") == "idr":
                assert nr_samples <= 2, (
                    f"For IDR to work you need two samples per condition, however you gave {nr_samples} samples for"
                    f" condition {condition} and assembly {assembly}"
                )

# ...on DE contrasts
if config.get("contrasts"):
    # check differential gene expression contrasts
    for contrast in list(config["contrasts"]):
        assert len(contrast.split("_")) >= 3, (
            f"\nCould not parse DESeq2 contrast '{contrast}'.\n"
            "A DESeq2 design contrast must be in the form '(batch+)column_target_reference'. See the docs for examples.\n"
        )
        _, _, _, _ = parse_contrast(contrast, samples, check=True)
