import groovy.io.FileType

//
// SV_VCF_CONVERSIONS: SUBWORKFLOW TO apply tool spesific conversions
//

params.options = [:]

include { MANTA_CONVERTINVERSION  } from '../../modules/nf-core/manta/convertinversion'  addParams( options: params.options )
include { GRIDSS_ANNOTATION       } from '../../modules/local/gridss_annotation'         addParams( options: params.options )
include { SVYNC                   } from '../../modules/nf-core/svync'                   addParams( options: params.options )
include { BGZIP_TABIX             } from '../../modules/local/bgzip_tabix'               addParams( options: params.options )

workflow SV_VCF_CONVERSIONS {
    take:
    input_ch    // channel: [val(meta), vcf]
    ref         // reference channel [ref.fa, ref.fa.fai]

    main:
    versions   = Channel.empty()

    //
    // MODULE: BGZIP_TABIX
    //
    // zip and index input test files

    BGZIP_TABIX(
        input_ch
    )
    versions = versions.mix(BGZIP_TABIX.out.versions)
    vcf_ch = BGZIP_TABIX.out.gz_tbi

    //
    // MODULE: SVYNC
    //
    //
    if(params.standardization){
        out_vcf_ch = Channel.empty()
        supported_callers = []
        new File("${projectDir}/assets/svync").eachFileRecurse (FileType.FILES) { supported_callers << it.baseName.replace(".yaml", "") }

        vcf_ch
            .branch{
                def supported = supported_callers.contains(it[0].id)
                if(!supported) {
                    log.warn("Standardization for SV caller '${it[0].id}' is not supported. Skipping standardization...")
                }
                tool:  supported
                other: !supported
            }
            .set{input}

        input.tool
            .map { meta, vcf, tbi ->
                config = file("${projectDir}/assets/svync/${meta.id}.yaml", checkIfExists:true)
                [ meta, vcf, tbi, config ]
            }
            .set {svync_ch}

        SVYNC(
            svync_ch
        )
        out_vcf_ch = out_vcf_ch.mix(SVYNC.out.vcf)
        out_vcf_ch = out_vcf_ch.mix(input.other)
        vcf_ch     = out_vcf_ch.map{it -> tuple(it[0], it[1], it[2])}
    }

    // Check tool spesific conversions
    if(params.bnd_to_inv){
        out_vcf_ch = Channel.empty()

        vcf_ch.branch{
            tool:  it[0].id == "manta" || it[0].id == "dragen"
            other: true}
            .set{input}
        //
        // MANTA_CONVERTINVERSION
        //
        // NOTE: should also work for dragen
        // Not working now!!!!!

        MANTA_CONVERTINVERSION(
            input.tool.map{it -> tuple(it[0], it[1])},
            ref.map { it -> tuple([id: it[0].getSimpleName()], it[0]) }
        )
        versions = versions.mix(MANTA_CONVERTINVERSION.out.versions)

        out_ch = MANTA_CONVERTINVERSION.out.vcf.join(MANTA_CONVERTINVERSION.out.tbi)
        out_vcf_ch = out_vcf_ch.mix(out_ch)
        out_vcf_ch = out_vcf_ch.mix(input.other)
        vcf_ch     = out_vcf_ch

        // https://github.com/srbehera/DRAGEN_Analysis/blob/main/convertInversion.py

    }

    if (params.gridss_annotate){
        out_vcf_ch = Channel.empty()

        vcf_ch.branch{
            tool:  it[0].id == "gridss"
            other: true}
            .set{input}

        //
        // GRIDSS_ANNOTATION
        //
        // https://github.com/PapenfussLab/gridss/blob/7b1fedfed32af9e03ed5c6863d368a821a4c699f/example/simple-event-annotation.R#L9
        // GRIDSS simple event annotation
        GRIDSS_ANNOTATION(
            input.tool,
            ref
        )
        versions = versions.mix(GRIDSS_ANNOTATION.out.versions)

        out_vcf_ch = out_vcf_ch.mix(GRIDSS_ANNOTATION.out.vcf)
        out_vcf_ch = out_vcf_ch.mix(input.other)
        vcf_ch     = out_vcf_ch
    }
    // https://github.com/EUCANCan/variant-extractor/blob/main/examples/vcf_to_csv.py

    emit:
    vcf_ch
    versions
}
