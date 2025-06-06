library("data.table")
library("readxl")
library("glue")
library("gggenes")
library("ggtext")
library("broom")
library("seqinr")
library("tidyverse")
needs::prioritize("dplyr")
setwd(here::here())

##----------------------------------------------------------------
##  Loading MAG statistic, Prokka annotations and query metadata  
##----------------------------------------------------------------
# Statistics on the HQ-MAGs from singleton et.al 2021
magstats. <- fread("./data/raw/magstats.tsv", sep = "\t")

# File with metadata on the query genes, e.g. function
query_metadata. <- excel_sheets("./data/raw/Query_figur.xlsx") %>%
  sapply(function(X) read_xlsx("./data/raw/Query_figur.xlsx", sheet = X, skip = 1), USE.NAMES = T) %>% 
  lapply(as.data.frame) %>% 
  `[`(!(names(.) %in% c("Abbreveations", "HA_S_pyogenes"))) %>%
  rbindlist() 

# Additional information of the prokka annotations
gff. <- fread("./data/raw/gff.tsv") %>%
  filter(!(ProkkaNO == "units")) %>% 
  mutate(Target_label = paste(ID, ProkkaNO, sep = "_"),
         ProkkaNO = as.numeric(ProkkaNO))


##---------------------------------------------------------------
##                         Main function                         
##---------------------------------------------------------------
proximity_filtration <- function(filename_psiblast,
                                 perc_id = 20,
                                 max_dist_prok = 8,
                                 max_dist_gene = 2000,
                                 min_genes = 2,
                                 flanking_genes = 2,
                                 magstats = magstats.,
                                 query_metadata = query_metadata.,
                                 gff = gff.,
                                 exclude_gene = "",
                                 essential_genes = NA
                                 ){
  filename_psiblast_col <- paste(filename_psiblast, collapse = "_")
  
  # Remove old results
  unlink(glue("./output/psi_operon_full/{filename_psiblast_col}.tsv"))
  unlink(glue("./output/psi_proxi_filt/{filename_psiblast_col}.tsv"))
  unlink(glue("./output/psi_percID_filt/{filename_psiblast_col}.tsv"))
  
  message(glue("Percent identity filtation ({filename_psiblast_col})"))
  
  # Loading raw psiblast results
  test1 <- filename_psiblast %>%
    paste0("./data/raw/psiblast/", ., ".txt") %>%
    lapply(
      fread,
      header = FALSE, sep = "\t", fill = TRUE, 
      col.names = c(
        "Query_label", "Target_label", "Percent_identity", "align_length",
        "mismatch", "gap_opens", "start_query", "end_query",
        "start_target", "end_target", "E_value", "Bit score")
    ) %>%
    bind_rows() %>%
    filter(!(Query_label %in% exclude_gene)) %>% 
  # Filtering
    subset(!is.na(E_value)) %>%
    filter(Percent_identity > perc_id) %>%
    group_by(Target_label) %>%
    filter(`Bit score` == max(`Bit score`)) %>%
    filter(!duplicated(Target_label)) %>%
  # Cleaning
    separate(Target_label, c("ID", "ProkkaNO"),
             sep = -5, remove = FALSE, extra = "merge") %>%
    mutate(
      ProkkaNO = as.numeric(ProkkaNO),
      ID = str_sub(ID, start = 1, end = -2)
      ) %>% 
  # Merging gff, MAG statistics and query information
    inner_join(gff, by = c("Target_label", "ID", "ProkkaNO") ) %>%
    left_join(magstats, by = "ID", keep = FALSE) %>%
    left_join(query_metadata %>% filter(Psiblast %in% filename_psiblast) %>% select(Genename, Function), 
              by = c("Query_label" = "Genename"), keep=FALSE)  %>%
    arrange(Target_label, ProkkaNO) %>%
  # Operon Grouping
    group_by(seqname, ID) %>%
    # define gene and prokka distance to prior psiblast hit
    mutate(prio_prok = replace_na(ProkkaNO - shift(ProkkaNO) < max_dist_prok, FALSE),
           prio_gene = replace_na(start - shift(end, 1) < max_dist_gene, FALSE)) %>%
    ungroup() %>% 
    # If a gene don't satisfy distance to prior gene, it's start of operon
    mutate(operon_place = ifelse(!(prio_prok | prio_gene), "start", NA),
           operon = ifelse(operon_place == "start", row_number(), NA)) %>%
    fill(operon, .direction = "down") %>%
    assign(x = "psi_perc_ID_filt", value = ., pos = 1)
  
  # Write percent identity filtered results
  dir.create("./output/psi_percID_filt", showWarnings = FALSE)
  write.table(psi_perc_ID_filt, 
              file = glue("./output/psi_percID_filt/{filename_psiblast_col}.tsv"),
              quote = F, sep = "\t", row.names = F)
  
  ##---------------------------------------------------------------
  message(glue("Proximity filtration ({filename_psiblast_col})"))
  # Operon number of genes filtering
  test2 <- psi_perc_ID_filt %>% group_by(operon) %>%
    filter(length(unique(Query_label)) >= min_genes & (all(essential_genes %in% Query_label) | any(is.na(essential_genes)))) %>%
    {if(nrow(.) == 0) stop("All results were filtrated away, try less strict filtration.") else .} %>% 
    select(-prio_prok, -prio_gene) %>% 
    ungroup() %>% 
    nest(cols = !c(ID, operon)) %>% 
    group_by(ID) %>% 
    mutate(letter = toupper(letters)[seq_along(unique(operon))],
           ID2 = case_when(
             length(unique(operon)) > 1 ~ paste(ID, letter, sep = "_"),
             TRUE ~ ID)
           ) %>% 
    select(-letter) %>% unnest(cols = c(cols)) %>% 
    assign(x = "psi_proxi_filt", value = ., pos = 1)
  
  # Write proximity filtered results
  dir.create("./output/psi_proxi_filt", showWarnings = FALSE)
  write.table(psi_proxi_filt, 
              file = glue("./output/psi_proxi_filt/{filename_psiblast_col}.tsv"), 
              quote = F, sep = "\t", row.names = F)
  message(glue("Operon expansion with intermediate and flanking genes ({filename_psiblast_col})"))
  ##---------------------------------------------------------------
  ## Expansion of filtered psiblast hits with surrounding genes
  # Identify surrounding genes
  test3 <- psi_proxi_filt %>% group_by(operon) %>%
    fill(ID2, .direction = "updown") %>% 
    summarise(
      ID = unique(ID),
      tig = unique(seqname),
      max = max(ProkkaNO),
      min = min(ProkkaNO)
      ) %>%
    full_join(gff, by = "ID") %>%
    group_by(operon) %>%
    filter(ProkkaNO <= (max + flanking_genes) &
           ProkkaNO >= (min - flanking_genes) & 
           seqname  == tig) %>%
    # Merging surrounding and psiblast genes
    full_join(psi_proxi_filt, by = c("operon", "ID", "seqname", "start", "end", "strand", "ProkkaNO", "Target_label")) %>%
    # Prepare for plotting in gggenes - see plot_operon.R
    group_by(operon) %>%
    mutate(
      # gggenes require 1 and -1 as strand direction
      strand = case_when(strand == "+" ~ 1, strand == "-" ~ -1, TRUE ~ 0),
      # Relative distances (start always minimum value of gene posistion)
      end = end - min(start),
      start = start - min(start),
      # converting AA numbers to nucleotide numbers
      end_target_plot =   ifelse(is.na(end_target),   end,   end_target   * 3 + start),
      start_target_plot = ifelse(is.na(start_target), start, start_target * 3 + start),
      # Assigning artificial percent identity to domains
      Percent_identity = ifelse(is.na(Percent_identity), 40, Percent_identity),
      # Order operons from highest bit score to lowest
      operon = factor(operon, levels = unique(arrange(., -`Bit score`)$operon))
      ) %>%
    fill(MiDAS3_6Tax, .direction = "updown") %>%
    fill(SILVA138Tax, .direction = "updown") %>%
    fill(GTDBTax, .direction = "updown") %>%
    fill(ID2, .direction = "updown") %>% 
    # ->ASSIGNING "psi_operon_full"<- 
    assign(x = "psi_operon_full", value = ., pos = 1)
  # Write operons with surrounding and intermediate genes
  dir.create("./output/psi_operon_full", showWarnings = FALSE)
  write.table(psi_operon_full, file = glue("./output/psi_operon_full/{filename_psiblast_col}.tsv"), 
              quote = F, sep = "\t", row.names = F)
  
  ##------------------------------------------------------------------
  ##  Export fasta files of identified genes, with surrounding genes  
  ##------------------------------------------------------------------
  message(glue("Saving FASTA files of genes in expanded operons ({filename_psiblast_col})"))
  for (f in unique(psi_operon_full$ID2)){
    dir.create(glue("./data/processed/fasta_output/{filename_psiblast_col}"), showWarnings = FALSE, recursive = TRUE)
    g <- unique(filter(psi_operon_full, ID2 == f)$ID)
    read.fasta(file = glue("./data/raw/MGP1000_HQMAG1083_prot_db_split/{g}.faa"), 
                            seqtype="AA", 
                            as.string=TRUE, 
                            set.attributes=FALSE) %>% 
      `[`(names(.) %in% psi_operon_full$Target_label) %>% 
      write.fasta(names=names(.), file.out=glue("./data/processed/fasta_output/{filename_psiblast_col}/{f}.faa"))
  }
}

