library(magrittr)

ebtbl.colnames <- c("tier", "speaker", "start.ms", "stop.ms", "duration", "value")
rttmtbl.colnames <- c("segment.type", "filename", "channel", "start.sc",
                      "duration.sc", "orthography", "speaker.type",
                      "speaker.tier", "conf.score", "signal.lookahead")
ann.marker <- "annotated-" ## ALSO USED IN CHATTR HELPERS
spch.seg.ptrn <- ".*Segment spkr=\"([A-Z]{3}).*startTime=\"([A-Z0-9.]+)\" endTime=\"([A-Z0-9.]+)\".*"
strt.clock.ptrn <- ".*<Recording num=\"\\d+\".*startTime=\"([A-Z0-9.]+)\" endTime=\"([A-Z0-9.]+)\""
paraling.ptrn <- "^&=[a-z]+[.!?]$"


# This must be in the rigid spchtbl format specified in the docs
read_spchtbl <- function(filepath, tbltype,
                         cliptier = ".alloneclip",
                         lxonly = FALSE,
                         nearonly = FALSE) {
  if (tbltype == "aas-elan-txt") {
    spchtbl <- aas_to_spchtbl(filepath, cliptier, lxonly)
  } else if (tbltype == "basic-speech-tbl") {
    spchtbl <- basictbl_to_spchtbl(filepath, cliptier, lxonly)
  } else if (tbltype == "lena-its") {
    spchtbl <- its_to_spchtbl(filepath, lxonly, nearonly)
  } else if (tbltype == "rttm") {
    spchtbl <- suppressWarnings(rttm_to_spchtbl(filepath, lxonly))
  } else {
    print(paste0("The specified file type, ", tbltype, ",isn't available!"))
    return()
  }
  return(spchtbl)
}

aas_to_spchtbl <- function(tbl, cliptier, lxonly) {
  aastbl <- readr::read_delim(file = tbl, delim = "\t",
    col_names = ebtbl.colnames, col_types = readr::cols(
      tier = readr::col_character(),
      speaker = readr::col_character(),
      start.ms = readr::col_integer(),
      stop.ms = readr::col_integer(),
      duration = readr::col_integer(),
      value = readr::col_character()
    ))
  # extract the top-level utterance tiers
  if (lxonly == TRUE) {
    wide.aastbl <- dplyr::filter(aastbl,
                          (tier == "CHI" & speaker == "CHI"  &
                            !(grepl(paraling.ptrn, value)) |
                             (tier == speaker &
                                !(grepl(paraling.ptrn, value)))))
  } else {
    wide.aastbl <- dplyr::filter(aastbl, tier == speaker)
  }
  if (nrow(wide.aastbl) == 0) {
    print("No utterances detected in file.")
  } else {
    # add in addressee information for each non-CHI utterance
    xds.aastbl <- dplyr::filter(aastbl, grepl('xds', tier)) %>%
      dplyr::select(speaker, start.ms, value) %>%
      dplyr::rename(addressee = value)
    if (NA %in% unique(xds.aastbl$speaker)) {
      print("WARNING: You may have a speaker information; make sure the correct Participant is entered in the metadata for each ELAN tier before exporting.")
    }
    if (lxonly == TRUE) {
      # now add in vocal maturity data
      vcm.aastbl <- dplyr::filter(aastbl, speaker == "CHI" & speaker != tier) %>%
        tidyr::spread(tier, value)
      if (!("vcm@CHI" %in% names(vcm.aastbl))) {
        vcm.aastbl$`vcm@CHI` <- NA
      }
      if (!("lex@CHI" %in% names(vcm.aastbl))) {
        vcm.aastbl$`lex@CHI` <- NA
      }
      if (!("mwu@CHI" %in% names(vcm.aastbl))) {
        vcm.aastbl$`mwu@CHI` <- NA
      }
      vcm.aastbl <- vcm.aastbl %>%
        dplyr::rename(vcm = 'vcm@CHI', lex = 'lex@CHI', mwu = 'mwu@CHI') %>%
        dplyr::mutate(non.lx = dplyr::case_when(
          vcm == "Y" ~ 1,
          vcm == "L" ~ 1,
          vcm == NA & lex == 0 ~ 1,
          vcm == NA & lex == NA & mwu == NA ~ 1,
          TRUE ~ 0
        )) %>%
        # remove non-linguistic vocalizations
        dplyr::filter(non.lx == 1) %>%
        dplyr::select(speaker, start.ms)
      # add all info to wide table
      wide.aastbl <- dplyr::anti_join(wide.aastbl, vcm.aastbl,
        by = c("speaker", "start.ms")) %>%
        dplyr::left_join(xds.aastbl, by = c("speaker", "start.ms")) %>%
        dplyr::select(speaker, start.ms, stop.ms, addressee)
    } else {
      wide.aastbl <- dplyr::left_join(wide.aastbl, xds.aastbl,
        by = c("speaker", "start.ms")) %>%
        dplyr::select(speaker, start.ms, stop.ms, addressee)
    }
    # add in information about the annotated regions
    # (if no annotation, stop and tell the user)
    if (cliptier %in% unique(aastbl$tier)) {
      clip.tbl <- dplyr::filter(aastbl, tier == cliptier) %>%
        dplyr::mutate(speaker = paste0(ann.marker, start.ms, "_", stop.ms, "-", value),
          addressee = NA) %>%
        dplyr::select(speaker, start.ms, stop.ms, addressee)
      wide.aastbl <- dplyr::bind_rows(clip.tbl, wide.aastbl) %>%
        dplyr::filter(speaker != cliptier)
      return(wide.aastbl)
    } else if (cliptier == ".alloneclip") {
      start.first.ann <- min(wide.aastbl$start.ms)
      stop.last.ann <- max(wide.aastbl$stop.ms)
      clip.tbl <- tibble::tibble(
        speaker = paste0(ann.marker, start.first.ann, "_",
                         stop.last.ann, "-", 1),
        start.ms = start.first.ann,
        stop.ms = stop.last.ann,
        addressee = NA
      )
      wide.aastbl <- dplyr::bind_rows(clip.tbl, wide.aastbl)
      return(wide.aastbl)
    }  else {
      print("Error: no rows from the clip tier found.")
    }
  }
}


basictbl_to_spchtbl <- function(tbl, cliptier, lxonly) {
  ebtbl.ncol <- readr::read_delim(file = tbl, delim = "\t", col_types = readr::cols(),
    col_names = FALSE) %>% ncol()
  if (ebtbl.ncol == 3) {
    ebtbl <- readr::read_delim(file = tbl, delim = "\t", col_types = readr::cols(),
      col_names = c("speaker", "start.ms", "stop.ms"))
    ebtbl <- ebtbl %>%
      dplyr::mutate(
        speaker = as.character(speaker),
        start.ms = as.integer(start.ms),
        stop.ms = as.integer(stop.ms)
      )
  } else if (ebtbl.ncol == 6) {
    ebtbl <- readr::read_delim(file = tbl, delim = "\t", col_types = readr::cols(),
      col_names = ebtbl.colnames)
    ebtbl <- ebtbl %>%
      dplyr::mutate(
        tier = as.character(tier),
        speaker = as.character(speaker),
        start.ms = as.integer(start.ms),
        stop.ms = as.integer(stop.ms),
        duration = as.integer(duration),
        value = as.character(value)
      ) %>%
      dplyr::select(tier, start.ms, stop.ms, value) %>%
      dplyr::rename(speaker = tier)
  } else {
    print("Invalid number of columns ({speaker,start.ms,stop.ms} or {tier,speaker,start.ms,stop.ms,duration,value})")
  }
  # subset to linguistic vocalizations if desired
  if (lxonly != FALSE) {
    if (is.character(lxonly)) {
      ebtbl <- ebtbl %>%
        dplyr::filter(grepl(lxonly, value) | speaker == cliptier)
    } else {
      print("Invalid value for lxonly parameter. Provide a pattern that matches linguistic vocalization annotations in the last column; see documentation for an example.")
    }
  }
  # add in information about the annotated regions
  # (if no annotation, stop and tell the user)
  if (cliptier %in% unique(ebtbl$speaker)) {
    clip.tbl <- dplyr::filter(ebtbl, speaker == cliptier) %>%
      dplyr::mutate(speaker = paste0(ann.marker, start.ms, "_", stop.ms, "-", value))
    ebtbl <- dplyr::bind_rows(clip.tbl, ebtbl) %>%
      dplyr::filter(speaker != cliptier)
    return(ebtbl)
  } else if (cliptier == ".alloneclip") {
    start.first.ann <- min(ebtbl$start.ms)
    stop.last.ann <- max(ebtbl$stop.ms)
    clip.tbl <- tibble::tibble(
      speaker = paste0(ann.marker, start.first.ann, "_",
                       stop.last.ann, "-", 1),
      start.ms = start.first.ann,
      stop.ms = stop.last.ann,
      value = NA
    )
    ebtbl <- dplyr::bind_rows(clip.tbl, ebtbl)
    return(ebtbl)
  } else {
    print("Error: Specified clip tier not found.")
  }
}


its_to_spchtbl <- function(its.file, lxonly, nearonly) {
  # Extract the speaker segment lines from the .its file
  its.data <- readr::read_lines(its.file)
  if (lxonly == TRUE) {
    # conversationInfo is only present on human vocalization segments labeled as
    # speech-related vocalizations, including the target child
    seg.spkr.lines <- which(grepl("Segment spkr=.*conversationInfo", its.data))
  } else {
    # this grabs all human vocalization segments (i.e., no TVN, no SIL, etc.)
    seg.spkr.lines <- which(grepl("Segment spkr=\"[FMC]", its.data))
  }
  its.spkr.data <- its.data[seg.spkr.lines]
  
  # Extract only the speaker, start, and stop times for each segment
  spchtbl <- stringr::str_match(
    its.spkr.data, spch.seg.ptrn)[,2:4]
  colnames(spchtbl) <- c("speaker", "start.LENA", "stop.LENA")
  
  # Reformat to a chattr spchtbl format
  spchtbl <- tibble::as_tibble(spchtbl) %>%
    dplyr::mutate(
      start.ms = as.integer(round(as.numeric(gsub("[A-Z]", "", start.LENA))*1000)),
      stop.ms = as.integer(round(as.numeric(gsub("[A-Z]", "", stop.LENA))*1000)),
      duration = stop.ms - start.ms
    )
  if ("value" %in% colnames(spchtbl)) {
    spchtbl <- spchtbl %>%
      dplyr::select(speaker, start.ms, stop.ms, duration, value)
  } else {
    spchtbl <- spchtbl %>%
      dplyr::mutate(value = NA) %>%
      dplyr::select(speaker, start.ms, stop.ms, duration, value)
  }
  # Simplify speaker tiers (collapse near/far or remove far as desired)
  if (nearonly == TRUE) {
    spchtbl <- dplyr::filter(spchtbl, grepl("N$", speaker))
  }
  spchtbl$speaker <- substr(spchtbl$speaker, 1, 2)
    
  # add in the recorded periods
  its.data.segments <- its.data[
    (which(grepl("<!-- [=]+ Flow of the Recordings", its.data)) + 1):
      (which(grepl("<!-- [=]+ All about the Bars", its.data)) - 1)]
  rec.start.time.lines <- which(grepl(strt.clock.ptrn, its.data.segments))
  rec.start.times <- stringr::str_match(
    its.data.segments[rec.start.time.lines], strt.clock.ptrn)[,2:3]
  rec.start.tbl <- tibble::tibble()
  recorded.portion <- 1
  if (length(rec.start.time.lines) == 1) {
    rec.start.tbl <- tibble::tibble(
      start.ms = as.integer(round(as.numeric(gsub("[A-Z]", "", rec.start.times[1]))*1000)),
      stop.ms = as.integer(round(as.numeric(gsub("[A-Z]", "", rec.start.times[2]))*1000)),
      duration = stop.ms - start.ms,
      speaker = paste0(ann.marker, start.ms, "_", stop.ms, "-", recorded.portion),
      value = NA) %>%
      dplyr::select(speaker, start.ms, stop.ms, duration, value)
  } else {
    for (i in 1:nrow(rec.start.times)) {
      new.rec <- tibble::tibble(
        start.ms = as.integer(round(as.numeric(gsub("[A-Z]", "", rec.start.times[i,1]))*1000)),
        stop.ms = as.integer(round(as.numeric(gsub("[A-Z]", "", rec.start.times[i,2]))*1000)),
        duration = stop.ms - start.ms,
        speaker = paste0(ann.marker, start.ms, "_", stop.ms, "-", recorded.portion),
        value = NA) %>%
        dplyr::select(speaker, start.ms, stop.ms, duration, value)
      rec.start.tbl <- dplyr::bind_rows(rec.start.tbl, new.rec)
      recorded.portion <- recorded.portion + 1
    }
  }
  spchtbl <- dplyr::bind_rows(rec.start.tbl, spchtbl)
  return(spchtbl)
}


rttm_to_spchtbl <- function(tbl, lxonly) {
  # Check if the table is space (traditional) or tab (ACLEW) separated
  rttm.delim <- dplyr::case_when(
    stringr::str_count(readLines(tbl, n = 1), " ") == 9 ~ " ",
    stringr::str_count(readLines(tbl, n = 1), "\t") > 6 |
      stringr::str_count(readLines(tbl, n = 1), "\t") < 10 ~ "\t",
    TRUE ~ "PROBLEM"
  )
  if (rttm.delim == "PROBLEM") {
    print("Error: rttm files must be either (a) 10 tab-delimited fields or (b) 8--10 space-delimited fields.")
  } else {
    rttmtbl <- readr::read_delim(file = tbl, delim = rttm.delim,
                          col_names = rttmtbl.colnames, col_types = readr::cols(
                            segment.type = readr::col_character(),
                            filename = readr::col_character(),
                            channel = readr::col_double(),
                            start.sc = readr::col_double(),
                            duration.sc = readr::col_double(),
                            orthography = readr::col_character(),
                            speaker.type = readr::col_character(), # XDS/VCM annots in ACLEW
                            speaker.tier = readr::col_character(),
                            conf.score = readr::col_double(),
                            signal.lookahead = readr::col_double())) %>%
      dplyr::mutate(
        speaker = speaker.tier,
        start.ms = start.sc * 1000,
        duration = duration.sc * 1000,
        stop.ms = start.ms + duration,
        value = speaker.type
      )  %>%
      dplyr::select(speaker, start.ms, stop.ms, value)
    # subset to linguistic vocalizations if desired
    if (lxonly != FALSE) {
      if (is.character(lxonly)) {
        rttmtbl <- rttmtbl %>%
          dplyr::filter(grepl(lxonly, value))
      } else {
        print("Invalid value for lxonly parameter. Provide a pattern that matches linguistic vocalization annotations in the sixth column of your rttm; see documentation for an example.")
      }
    }
    # add clip information for whole file
    start.first.ann <- min(rttmtbl$start.ms)
    stop.last.ann <- max(rttmtbl$stop.ms)
    clip.tbl <- tibble::tibble(
      speaker = paste0(ann.marker, start.first.ann, "_",
                       stop.last.ann, "-", 1),
      start.ms = start.first.ann,
      stop.ms = stop.last.ann,
      value = NA
    )
    rttmtbl <- dplyr::bind_rows(clip.tbl, rttmtbl)
    return(rttmtbl)
  }
}


