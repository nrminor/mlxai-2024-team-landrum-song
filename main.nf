#!/usr/bin/env nextflow

nextflow.enable.dsl = 2


// prints to the screen and to the log
log.info """
         ██████ ██      ██ ███    ██  ██████ ██      ██    ██ ███████ ████████ ███████ ██████
        ██      ██      ██ ████   ██ ██      ██      ██    ██ ██         ██    ██      ██   ██
        ██      ██      ██ ██ ██  ██ ██      ██      ██    ██ ███████    ██    █████   ██████
        ██      ██      ██ ██  ██ ██ ██      ██      ██    ██      ██    ██    ██      ██   ██
         ██████ ███████ ██ ██   ████  ██████ ███████  ██████  ███████    ██    ███████ ██   ██


        ClinCluster (version 0.1.0)
        A pipeline for clustering ClinVar condition entries into groups based on whether they
        are alternate names for the same underlying condition. The pipeline uses an LLM DBSCAN
        to assign cluster indices to each condition in input variants for a given gene.
        ===================================
        gene list       : ${params.genelist}
        results_dir     : ${params.results}
        user email      : ${params.email}
        tuning param    : ${params.tuningparam}

        [debug mode     : ${params.debugmode}]
        [cleanup        : ${params.cleanup}]
        """
        .stripIndent()


// WORKFLOW SPECIFICATION
// --------------------------------------------------------------- //
workflow {

	// input channels
    ch_genelist = Channel
        .fromPath( params.genelist )
        .splitCsv( header: false, sep: "\t" )
        .flatten( )

	// Workflow steps
    RETRIEVE_DATA (
        ch_genelist
    )

    CLUSTER_WITH_LLM (
        RETRIEVE_DATA.out
    )

    FIND_QUALIFYING_RECORDS (
        CLUSTER_WITH_LLM.out
    )

    // MAP_TO_ORIGINAL_DATA (
    //     FIND_QUALIFYING_RECORDS.out
    // )


}
// --------------------------------------------------------------- //



// DERIVATIVE PARAMETER SPECIFICATION
// --------------------------------------------------------------- //

// Using debugmode setting to decide how to handle errors
if ( params.debugmode == true ){
	params.errorMode = 'terminate'
} else {
	params.errorMode = 'ignore'
}

// Additional parameters that are derived from parameters set in nextflow.config
params.retrieved = params.results + "/01_retrieved_data"
params.embeddings = params.results + "/02_llm_embeddings"
params.clusters = params.results + "/03_unverified_clusters"
params.verified = params.results + "/04_qualifying_clusters"
params.remapped = params.results + "/05_clinvar_with_clusters"

// --------------------------------------------------------------- //




// PROCESS SPECIFICATION
// --------------------------------------------------------------- //

process RETRIEVE_DATA {

	tag "${gene}"
	publishDir params.retrieved, mode: 'copy', overwrite: true

	errorStrategy { sleep(Math.pow(2, task.attempt) * 100 as long); return 'retry' }
	maxRetries 2

	input:
	val gene

	output:
	tuple val(gene), path("${gene}_formatted_unique_conditions.json"), path("${gene}_variants_extracted.json")

	script:
    println("Retrieving data for the ${gene}")
	"""
	pull_and_extract_clinvar.py \
    --gene ${gene} \
    --email ${params.email}
	"""
}

process CLUSTER_WITH_LLM {

	tag "${gene}"
	publishDir params.verified, mode: 'copy', overwrite: true

	errorStrategy { task.attempt < 3 ? 'retry' : params.errorMode }
	maxRetries 2

	input:
	tuple val(gene), path(unique_conditions), path(full_variants)

	output:
	tuple val(gene), path("${gene}_clusters.json"), path(full_variants)

	script:
	"""
    llm embed-multi diseases \
    ${unique_conditions} \
    --database ${gene}.db \
    --model sentence-transformers/all-MiniLM-L6-v2 \
    --store

	llm cluster diseases \
    --database ${gene}.db \
    ${params.tuningparam} > ${gene}_clusters.json
	"""
}

process FIND_QUALIFYING_RECORDS {

	tag "${gene}"
	publishDir params.remapped, mode: 'copy', pattern: "*qualifying*", overwrite: true

	errorStrategy { task.attempt < 3 ? 'retry' : params.errorMode }
	maxRetries 2

	input:
	tuple val(gene), path(llm_clusters), path(full_variants)

	output:
	tuple val(gene), path("${gene}_qualifying_records.json"), path(full_variants)

	script:
	"""
	check_duplicate.py ${gene}
	"""
}

// --------------------------------------------------------------- //
