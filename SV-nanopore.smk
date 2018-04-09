configfile: "config.yaml"

from glob import glob
import os


def get_samples(wildcards):
    return config["samples"][wildcards.sample]


rule all:
    input:
        expand("SV-plots/SV-length_{caller}_genotypes_{sample}.png",
               sample=config["samples"],
               caller=["sniffles", "nanosv"]),
        # expand("SV-plots/SV-length_sniffles_genotypes_{sample}.png",
        #        sample=config["samples"]),
        "sniffles_combined/annot_genotypes.vcf",
        "nanosv_combined/annot_genotypes.vcf",
        "all_combined/annot_genotypes.vcf",
        "mosdepth/regions.combined.gz",
        "mosdepth_global_plot/global.html",


rule minimap2:
    input:
        expand("minimap2_alignment/{sample}.bam.bai", sample=config["samples"]),


rule minimap2_align:
    input:
        fq = get_samples,
        genome = config["genome"]
    output:
        "minimap2_alignment/{sample}.bam"
    threads:
        8
    log:
        "logs/minimap2/{sample}.log"
    shell:
        "minimap2 -a -t {threads} {input.genome} {input.fq}/*.fastq.gz | \
         samtools sort -@ {threads} -o {output} - 2> {log}"

rule ngmlr:
    input:
        fq = get_samples,
        genome = config["genome"]
    output:
        protected("ngmlr_alignment/{sample}.bam")
    threads:
        24
    log:
        "logs/ngmlr/{sample}.log"
    shell:
        "zcat {input.fq}/*.fastq.gz | \
         ngmlr -x ont -t {threads} -r {input.genome} | \
         samtools sort -@ {threads} -o {output} - 2> {log}"


rule samtools_index:
    input:
        "{aligner}_alignment/{sample}.bam"
    output:
        "{aligner}_alignment/{sample}.bam.bai"
    threads: 12
    log:
        "logs/samtools_index/{aligner}_{sample}.log"
    shell:
        "samtools index -@ {threads} {input} 2> {log}"


rule sniffles_call:
    input:
        "ngmlr_alignment/{sample}.bam"
    output:
        protected("sniffles_calls/{sample}.vcf")
    threads: 8
    log:
        "logs/sniffles_call/{sample}.log"
    shell:
        "sniffles --mapped_reads {input} --vcf {output} --threads {threads} 2> {log}"


rule sniffles_genotype:
    input:
        bam = "ngmlr_alignment/{sample}.bam",
        ivcf = "sniffles_combined/calls.vcf"
    output:
        "sniffles_genotypes/{sample}.vcf"
    threads: 8
    log:
        "logs/sniffles_genotype/{sample}.log"
    shell:
        "sniffles --mapped_reads {input.bam} \
                  --vcf {output} \
                  --threads {threads} \
                  --Ivcf {input.ivcf} 2> {log}"

rule split_bam:
    input:
        "ngmlr_alignment/{sample}.bam"
    output:
        dynamic("split_ngmlr_alignment/{sample}.REF_{chromosome}.bam")
    log:
        "logs/bamtools_split/{sample}.log"
    shell:
        "bamtools split -in {input} -reference"


rule nanosv:
    input:
        bam = dynamic("split_ngmlr_alignment/{sample}.REF_{chromosome}.bam"),
        bai = dynamic("split_ngmlr_alignment/{sample}.REF_{chromosome}.bam.bai")
    output:
        dynamic("split_nanosv_genotypes/{sample}_{chromosome}.vcf")
    params:
        bed = config["annotbed"],
        samtools = "samtools"
    log:
        "logs/nanosv/{sample}.log"
    shell:
        "NanoSV --bed {params.bed} -s {params.samtools} {input.bam} -o {output} 2> {log}"


rule cat_vcfs:
    input:
        dynamic("split_nanosv_genotypes/{sample}_{chromosome}.vcf")
    output:
        "nanosv_genotypes/{sample}.vcf"
    log:
        "logs/vcf-concat/{sample}.log"
    shell:
        "vcf-concat {input} > {output} 2> {log}"

rule survivor:
    input:
        expand("{{caller}}_{{stage}}/{sample}.vcf", sample=config["samples"])
    output:
        vcf = temp("{caller}_combined/{stage}.vcf"),
        fofn = temp("{caller}_{stage}/samples.fofn")
    params:
        distance = 1000,
        caller_support = 1,
        same_type = 1,
        same_strand = -1,
        estimate_distance = -1,
        minimum_size = -1,
    log:
        "logs/{caller}/surivor_{stage}.log"
    shell:
        "ls {input} > {output.fofn} ; \
        SURVIVOR merge {output.fofn} {params.distance} {params.caller_support} \
        {params.same_type} {params.same_strand} {params.estimate_distance}  \
        {params.minimum_size} {output.vcf} 2> {log}"

rule survivor_all:
    input:
        expand("{caller}_genotypes/{sample}.vcf",
               sample=config["samples"], caller=["sniffles", "nanosv"])
    output:
        vcf = temp("all_combined/genotypes.vcf"),
        fofn = temp("all_combined/samples.fofn")
    params:
        distance = 1000,
        caller_support = 1,
        same_type = 1,
        same_strand = -1,
        estimate_distance = -1,
        minimum_size = -1,
    log:
        "logs/all/surivor.log"
    shell:
        "ls {input} > {output.fofn} ; \
        SURVIVOR merge {output.fofn} {params.distance} {params.caller_support} \
        {params.same_type} {params.same_strand} {params.estimate_distance}  \
        {params.minimum_size} {output.vcf} 2> {log}"


rule mosdepth:
    input:
        bam = "ngmlr_alignment/{sample}.bam",
        bai = "ngmlr_alignment/{sample}.bam.bai"
    threads: 4
    output:
        protected("mosdepth/{sample}.mosdepth.global.dist.txt"),
        protected("mosdepth/{sample}.regions.bed.gz"),
    params:
        windowsize = 500,
        prefix = "{sample}",
    log:
        "logs/mosdepth/mosdepth_{sample}.log"
    shell:
        "mosdepth --threads {threads} \
                  -n \
                  --by {params.windowsize} \
                  mosdepth/{params.prefix} {input.bam} 2> {log}"


rule mosdepth_combine:
    input:
        expand("mosdepth/{sample}.regions.bed.gz", sample=config["samples"])
    output:
        "mosdepth/regions.combined.gz"
    log:
        "logs/mosdepth/mosdepth_combine.log"
    shell:
        os.path.join(workflow.basedir, "scripts/combine_mosdepth.py") + \
            " {input} -o {output} 2> {log}"


rule mosdepth_global_plot:
    input:
        expand("mosdepth/{sample}.mosdepth.global.dist.txt", sample=config["samples"])
    output:
        "mosdepth_global_plot/global.html"
    log:
        "logs/mosdepth/mosdepth_global_plot.log"
    shell:
        os.path.join(workflow.basedir, "scripts/mosdepth_plot-dist.py") + \
            " {input} -o {output} 2> {log}"


rule SV_length_plot:
    input:
        "{caller}_{stage}/{sample}.vcf"
    output:
        "SV-plots/SV-length_{caller}_{stage}_{sample}.png"
    log:
        "logs/svplot/svlength_{caller}_{stage}_{sample}.log"
    shell:
        os.path.join(workflow.basedir, "scripts/SV-length-plot.py") + " {input} {output} 2> {log}"


rule SV_plot_carriers:
    input:
        "sniffles_combined/genotypes.vcf"
    output:
        "SV-plots/SV-carriers.png"
    log:
        "logs/svplot/svcarriers.log"
    shell:
        os.path.join(workflow.basedir, "scripts/SV-carriers-plot.py") + \
            " {input} {output} 2> {log}"


rule sort_vcf:
    input:
        "{caller}_combined/genotypes.vcf"
    output:
        temp("{caller}_combined/sorted_genotypes.vcf")
    log:
        "logs/sort_vcf/sorting_{caller}.log"
    threads: 8
    shell:
        "vcf-sort {input} > {output} 2> {log}"


rule annotate_vcf:
    input:
        "{caller}_combined/sorted_genotypes.vcf"
    output:
        "{caller}_combined/annot_genotypes.vcf"
    log:
        "logs/annotate_vcf/annotate_{caller}.log"
    params:
        conf = "/home/wdecoster/projects/SV-snakemake/configuration/vcfanno_conf.toml"
    threads: 8
    shell:
        "vcfanno -ends -p {threads} {params.conf} {input} > {output} 2> {log}"


# add mosdepth information and plots on called sites
