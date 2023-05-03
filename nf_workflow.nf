#!/usr/bin/env nextflow
nextflow.enable.dsl=2

// Spectra as input
params.input_spectra = "data/input_spectra"

// Libraries
params.input_libraries = "data/library"

// Metadata
params.input_metadata = "data/metadata.tsv"

// Parameters
params.min_cluster_size = "2"

params.pm_tolerance = "2.0"
params.fragment_tolerance = "0.5"

// Filtereing
params.min_peak_intensity = "0.0"

// Molecular Networking Options
params.similarity = "gnps"

params.parallelism = 24
params.networking_min_matched_peaks = 6
params.networking_min_cosine = 0.7
params.networking_max_shift = 1000

// Workflow Boiler Plate
params.OMETALINKING_YAML = "flow_filelinking.yaml"
params.OMETAPARAM_YAML = "job_parameters.yaml"

TOOL_FOLDER = "$baseDir/bin"

process filesummary {
    publishDir "./nf_output", mode: 'copy'

    conda "$TOOL_FOLDER/conda_env.yml"

    input:
    file inputSpectra

    output:
    file 'summaryresult.tsv'

    """
    python $TOOL_FOLDER/scripts/filesummary.py $inputSpectra summaryresult.tsv $TOOL_FOLDER/binaries/msaccess
    """
}

process mscluster {
    publishDir "./nf_output", mode: 'copy'

    conda "$TOOL_FOLDER/conda_env.yml"

    input:
    file inputSpectra

    output:
    file 'output/specs_ms.mgf'
    file 'output/clusterinfo.tsv'
    file 'output/clustersummary.tsv'

    """
    mkdir output
    python $TOOL_FOLDER/scripts/mscluster_wrapper.py \
    $inputSpectra $TOOL_FOLDER/binaries \
    spectra \
    output \
    --min_cluster_size $params.min_cluster_size \
    --pm_tolerance $params.pm_tolerance \
    --fragment_tolerance $params.fragment_tolerance \
    --min_peak_intensity $params.min_peak_intensity
    """
}

// Library Search
process librarySearchData {
    conda "$TOOL_FOLDER/conda_env.yml"

    input:
    each file(input_library)
    each file(input_spectrum)

    output:
    file 'search_results/*' optional true

    """
    mkdir search_results
    python $TOOL_FOLDER/scripts/library_search_wrapper.py \
    $input_spectrum $input_library search_results \
    $TOOL_FOLDER/binaries/convert \
    $TOOL_FOLDER/binaries/main_execmodule.allcandidates
    """
}

process librarymergeResults {
    publishDir "./nf_output/library_intermediate", mode: 'copy'

    conda "$TOOL_FOLDER/conda_env.yml"

    input:
    path "results/*"

    output:
    path 'merged_results.tsv'

    """
    python $TOOL_FOLDER/scripts/tsv_merger.py \
    results merged_results.tsv
    """
}

process librarygetGNPSAnnotations {
    publishDir "./nf_output/library", mode: 'copy'

    conda "$TOOL_FOLDER/conda_env.yml"

    input:
    path "merged_results.tsv"

    output:
    path 'merged_results_with_gnps.tsv'

    """
    python $TOOL_FOLDER/scripts/getGNPS_library_annotations.py \
    merged_results.tsv \
    merged_results_with_gnps.tsv
    """
}

// Molecular Networking
process networkingGNPSPrepParams {
    publishDir "./nf_output/networking", mode: 'copy'

    conda "$TOOL_FOLDER/conda_env.yml"

    input:
    file spectrum_file

    output:
    file "params/*"

    """
    mkdir params
    python $TOOL_FOLDER/scripts/prep_molecular_networking_parameters.py \
        "$spectrum_file" \
        "params" \
        --parallelism "$params.parallelism" \
        --min_matched_peaks "$params.networking_min_matched_peaks" \
        --ms2_tolerance "$params.fragment_tolerance" \
        --pm_tolerance "$params.pm_tolerance" \
        --min_cosine "$params.networking_min_cosine" \
        --max_shift "$params.networking_max_shift"
    """
}

process calculatePairs {
    publishDir "./nf_output/temp_pairs", mode: 'copy'

    conda "$TOOL_FOLDER/conda_env.yml"

    input:
    file spectrum_file
    each file(params_file)

    output:
    file "*_aligns.tsv" optional true

    """
    $TOOL_FOLDER/binaries/main_execmodule \
        ExecMolecularParallelPairs \
        "$params_file" \
        -ccms_INPUT_SPECTRA_MS2 $spectrum_file \
        -ccms_output_aligns ${params_file}_aligns.tsv
    """
}

// Creating the metadata file
// TODO: Finish this
process createMetadataFile {
    publishDir "./nf_output/metadata", mode: 'copy'

    conda "$TOOL_FOLDER/conda_env.yml"

    input:
    file input_metadata

    output:
    file "merged_metadata.tsv"

    //script in case its NO_FILE
    """
    python $TOOL_FOLDER/scripts/merge_metadata.py \
    $input_metadata \
    merged_metadata.tsv
    """
}

// Calculating the groupings
process calculateGroupings {
    publishDir "./nf_output/networking", mode: 'copy'

    conda "$TOOL_FOLDER/conda_env.yml"

    input:
    file input_metadata
    file input_clustersummary
    file input_clusterinfo

    output:
    file "clustersummary_with_groups.tsv"

    """
    python $TOOL_FOLDER/scripts/group_abundances.py \
    $input_clusterinfo \
    $input_clustersummary \
    $input_metadata \
    clustersummary_with_groups.tsv
    """
}

// Filtering the network
process filterNetwork {
    publishDir "./nf_output/networking", mode: 'copy'

    conda "$TOOL_FOLDER/conda_env.yml"

    input:
    file input_pairs

    output:
    file "filtered_pairs.tsv"

    """
    python $TOOL_FOLDER/scripts/filter_networking_edges.py \
    $input_pairs \
    filtered_pairs.tsv \
    filtered_pairs_old_format.tsv
    """
}

// Enriching the Cluster Summary
process enrichClusterSummary {
    publishDir "./nf_output/networking", mode: 'copy'

    conda "$TOOL_FOLDER/conda_env.yml"

    input:
    file input_clustersummary
    file input_filtered_pairs
    file input_library_matches

    output:
    file "clustersummary_with_network.tsv"

    """
    python $TOOL_FOLDER/scripts/enrich_cluster_summary.py \
    $input_clustersummary \
    $input_filtered_pairs \
    $input_library_matches \
    clustersummary_with_network.tsv
    """
}


workflow {
    input_spectra_ch = Channel.fromPath(params.input_spectra)

    filesummary(input_spectra_ch)

    (clustered_spectra_ch, clusterinfo_ch, clustersummary_ch) = mscluster(input_spectra_ch)

    // Library Search
    libraries_ch = Channel.fromPath(params.input_libraries + "/*.mgf" )
    search_results_ch = librarySearchData(libraries_ch, clustered_spectra_ch)
    merged_results_ch = librarymergeResults(search_results_ch.collect())
    gnps_library_results_ch = librarygetGNPSAnnotations(merged_results_ch)

    // Networking
    params_ch = networkingGNPSPrepParams(clustered_spectra_ch)
    networking_results_temp_ch = calculatePairs(clustered_spectra_ch, params_ch.collect())

    merged_networking_pairs_ch = networking_results_temp_ch.collectFile(name: "merged_pairs.tsv", storeDir: "./nf_output/networking", keepHeader: true)

    // Filtering the network
    filtered_networking_pairs_ch = filterNetwork(merged_networking_pairs_ch)


    // Handling Metadata, if we don't have one, we'll set it to be empty
    if(params.metadata_filename.length() > 0){
        if(params.metadata_filename == "NO_FILE"){
            input_metadata_ch = Channel.of(file("NO_FILE"))
        }
        else{
            input_metadata_ch = Channel.fromPath(params.metadata_filename).first()
        }
    }
    else{
        input_metadata_ch = Channel.of(file("NO_FILE"))
    }

    merged_metadata_ch = createMetadataFile(input_metadata_ch)

    // Enriching the network with group mappings
    clustersummary_with_groups_ch = calculateGroupings(merged_metadata_ch, clustersummary_ch, clusterinfo_ch)

    // Adding component and library informaiton
    clustersummary_with_network_ch = enrichClusterSummary(clustersummary_with_groups_ch, filtered_networking_pairs_ch, gnps_library_results_ch)

    

}