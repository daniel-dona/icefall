#!/usr/bin/env bash

set -eou pipefail

nj=24
stage=$1
stop_stage=100

# Split data/${lang}set to this number of pieces
# This is to avoid OOM during feature extraction.
num_splits=1000

# In case you want to use all validated data
use_validated=false

# In case you are willing to take the risk and use invalidated data
use_invalidated=false

# We assume dl_dir (download dir) contains the following
# directories and files. If not, they will be downloaded
# by this script automatically.
#
#  - $dl_dir/$release/$lang
#      This directory contains the following files downloaded from
#       https://mozilla-common-voice-datasets.s3.dualstack.us-west-2.amazonaws.com/${release}/${release}-${lang}.tar.gz
#
#     - clips
#     - dev.tsv
#     - invalidated.tsv
#     - other.tsv
#     - reported.tsv
#     - test.tsv
#     - train.tsv
#     - validated.tsv
#
#  - $dl_dir/musan
#      This directory contains the following directories downloaded from
#       http://www.openslr.org/17/
#
#     - music
#     - noise
#     - speech

dl_dir=$PWD/download
release=cv-corpus-17.0-2024-03-15
lang=$2 #en, de, it, etc...
perturb_speed=false

. shared/parse_options.sh || exit 1

# vocab size for sentence piece models.
# It will generate data/${lang}/lang_bpe_xxx,
# data/${lang}/lang_bpe_yyy if the array contains xxx, yyy
vocab_sizes=(
  # 5000
  # 2000
  # 1000
  500
)

# All files generated by this script are saved in "data/${lang}".
# You can safely remove "data/${lang}" and rerun this script to regenerate it.
mkdir -p data/${lang}

log() {
  # This function is from espnet
  local fname=${BASH_SOURCE[1]##*/}
  echo -e "$(date '+%Y-%m-%d %H:%M:%S') (${fname}:${BASH_LINENO[0]}:${FUNCNAME[1]}) $*"
}

log "dl_dir: $dl_dir"

if ! command -v ffmpeg &> /dev/null; then
  echo "This dataset requires ffmpeg"
  echo "Please install ffmpeg first"
  echo ""
  echo "  sudo apt-get install ffmpeg"
  exit 1
fi

if [ $stage -le 0 ] && [ $stop_stage -ge 0 ]; then
  log "Stage 0: Download data"

  # Disabled as v17 is not working and probably will not work in the future as email requirement is enforced
  
  # If you have pre-downloaded it to /path/to/$release,
  # you can create a symlink
  #
  #   ln -sfv /path/to/$release $dl_dir/$release
  #
  #if [ ! -d $dl_dir/$release/$lang/clips ]; then
  #  lhotse download commonvoice --languages $lang --release $release $dl_dir
  #fi

  # If you have pre-downloaded it to /path/to/musan,
  # you can create a symlink
  #
  #   ln -sfv /path/to/musan $dl_dir/
  #
  if [ ! -d $dl_dir/musan ]; then
    lhotse download musan $dl_dir
  fi
fi

if [ $stage -le 1 ] && [ $stop_stage -ge 1 ]; then
  log "Stage 1: Prepare CommonVoice manifest"
  # We assume that you have downloaded the CommonVoice corpus
  # to $dl_dir/$release
  mkdir -p data/${lang}/manifests
  if [ ! -e data/${lang}/manifests/.cv-${lang}.done ]; then
    lhotse prepare commonvoice --language $lang -j $nj $dl_dir/$release data/${lang}/manifests
    
    if [ $use_validated = true ] && [ ! -f data/${lang}/manifests/.cv-${lang}.validated.done ]; then
      log "Also prepare validated data"
      lhotse prepare commonvoice \
        --split validated \
        --language $lang \
        -j $nj $dl_dir/$release data/${lang}/manifests
      touch data/${lang}/manifests/.cv-${lang}.validated.done
    fi

    if [ $use_invalidated = true ] && [ ! -f data/${lang}/manifests/.cv-${lang}.invalidated.done ]; then
      log "Also prepare invalidated data"
      lhotse prepare commonvoice \
        --split invalidated \
        --language $lang \
        -j $nj $dl_dir/$release data/${lang}/manifests
      touch data/${lang}/manifests/.cv-${lang}.invalidated.done
    fi
    
    touch data/${lang}/manifests/.cv-${lang}.done
  fi

  # Note: in Linux, you can install jq with the following command:
  # 1. wget -O jq https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64
  # 2. chmod +x ./jq
  # 3. cp jq /usr/bin
  if [ $use_validated = true ]; then
    log "Getting cut ids from dev/test sets for later use"
    gunzip -c data/${lang}/manifests/cv-${lang}_supervisions_test.jsonl.gz \
      | jq '.id' | sed 's/"//g' > data/${lang}/manifests/cv-${lang}_test_ids
    
    gunzip -c data/${lang}/manifests/cv-${lang}_supervisions_dev.jsonl.gz \
      | jq '.id' | sed 's/"//g' > data/${lang}/manifests/cv-${lang}_dev_ids
  fi
fi

if [ $stage -le 2 ] && [ $stop_stage -ge 2 ]; then
  log "Stage 2: Prepare musan manifest"
  # We assume that you have downloaded the musan corpus
  # to data/musan
  mkdir -p data/manifests
  if [ ! -e data/manifests/.musan.done ]; then
    lhotse prepare musan $dl_dir/musan data/manifests
    touch data/manifests/.musan.done
  fi
fi

if [ $stage -le 3 ] && [ $stop_stage -ge 3 ]; then
  log "Stage 3: Preprocess CommonVoice manifest"
  if [ ! -e data/${lang}/fbank/.preprocess_complete ]; then
    ./local/preprocess_commonvoice.py  --language $lang
    touch data/${lang}/fbank/.preprocess_complete
  fi
  
  if [ $use_validated = true ] && [ ! -f data/${lang}/fbank/.validated.preprocess_complete ]; then
    log "Also preprocess validated data"
    ./local/preprocess_commonvoice.py  --language $lang --dataset validated
    touch data/${lang}/fbank/.validated.preprocess_complete
  fi

  if [ $use_invalidated = true ] && [ ! -f data/${lang}/fbank/.invalidated.preprocess_complete ]; then
    log "Also preprocess invalidated data"
    ./local/preprocess_commonvoice.py  --language $lang --dataset invalidated
    touch data/${lang}/fbank/.invalidated.preprocess_complete
  fi
fi

if [ $stage -le 4 ] && [ $stop_stage -ge 4 ]; then
  log "Stage 4: Compute fbank for dev and test subsets of CommonVoice"
  mkdir -p data/${lang}/fbank
  if [ ! -e data/${lang}/fbank/.cv-${lang}_dev_test.done ]; then
    ./local/compute_fbank_commonvoice_dev_test.py --language $lang
    touch data/${lang}/fbank/.cv-${lang}_dev_test.done
  fi
fi

if [ $stage -le 5 ] && [ $stop_stage -ge 5 ]; then
  log "Stage 5: Split train subset into ${num_splits} pieces"
  split_dir=data/${lang}/fbank/cv-${lang}_train_split_${num_splits}
  if [ ! -e $split_dir/.cv-${lang}_train_split.done ]; then
    lhotse split $num_splits ./data/${lang}/fbank/cv-${lang}_cuts_train_raw.jsonl.gz $split_dir
    touch $split_dir/.cv-${lang}_train_split.done
  fi

  split_dir=data/${lang}/fbank/cv-${lang}_validated_split_${num_splits}
  if [ $use_validated = true ] && [ ! -f $split_dir/.cv-${lang}_validated.done ]; then
    log "Also split validated data"
    lhotse split $num_splits ./data/${lang}/fbank/cv-${lang}_cuts_validated_raw.jsonl.gz $split_dir
    touch $split_dir/.cv-${lang}_validated.done
  fi

  split_dir=data/${lang}/fbank/cv-${lang}_invalidated_split_${num_splits}
  if [ $use_invalidated = true ] && [ ! -f $split_dir/.cv-${lang}_invalidated.done ]; then
    log "Also split invalidated data"
    lhotse split $num_splits ./data/${lang}/fbank/cv-${lang}_cuts_invalidated_raw.jsonl.gz $split_dir
    touch $split_dir/.cv-${lang}_invalidated.done
  fi
fi

if [ $stage -le 6 ] && [ $stop_stage -ge 6 ]; then
  log "Stage 6: Compute features for train subset of CommonVoice"
  if [ ! -e data/${lang}/fbank/.cv-${lang}_train.done ]; then
    ./local/compute_fbank_commonvoice_splits.py \
      --num-workers $nj \
      --batch-duration 200 \
      --start 0 \
      --num-splits $num_splits \
      --language $lang \
      --perturb-speed $perturb_speed
    touch data/${lang}/fbank/.cv-${lang}_train.done
  fi

  if [ $use_validated = true ] && [ ! -f data/${lang}/fbank/.cv-${lang}_validated.done ]; then
    log "Also compute features for validated data"
    ./local/compute_fbank_commonvoice_splits.py \
      --subset validated \
      --num-workers $nj \
      --batch-duration 200 \
      --start 0 \
      --num-splits $num_splits \
      --language $lang \
      --perturb-speed $perturb_speed
    touch data/${lang}/fbank/.cv-${lang}_validated.done
  fi

  if [ $use_invalidated = true ] && [ ! -f data/${lang}/fbank/.cv-${lang}_invalidated.done ]; then
    log "Also compute features for invalidated data"
    ./local/compute_fbank_commonvoice_splits.py \
      --subset invalidated \
      --num-workers $nj \
      --batch-duration 200 \
      --start 0 \
      --num-splits $num_splits \
      --language $lang \
      --perturb-speed $perturb_speed
    touch data/${lang}/fbank/.cv-${lang}_invalidated.done
  fi
fi

if [ $stage -le 7 ] && [ $stop_stage -ge 7 ]; then
  log "Stage 7: Combine features for train"
  if [ ! -f data/${lang}/fbank/cv-${lang}_cuts_train.jsonl.gz ]; then
    pieces=$(find data/${lang}/fbank/cv-${lang}_train_split_${num_splits} -name "cv-${lang}_cuts_train.*.jsonl.gz")
    lhotse combine $pieces data/${lang}/fbank/cv-${lang}_cuts_train.jsonl.gz
  fi

  if [ $use_validated = true ] && [ -f data/${lang}/fbank/.cv-${lang}_validated.done ]; then
    log "Also combine features for validated data"
    pieces=$(find data/${lang}/fbank/cv-${lang}_validated_split_${num_splits} -name "cv-${lang}_cuts_validated.*.jsonl.gz")
    lhotse combine $pieces data/${lang}/fbank/cv-${lang}_cuts_validated.jsonl.gz
    touch data/${lang}/fbank/.cv-${lang}_validated.done
  fi

  if [ $use_invalidated = true ] && [ -f data/${lang}/fbank/.cv-${lang}_invalidated.done ]; then
    log "Also combine features for invalidated data"
    pieces=$(find data/${lang}/fbank/cv-${lang}_invalidated_split_${num_splits} -name "cv-${lang}_cuts_invalidated.*.jsonl.gz")
    lhotse combine $pieces data/${lang}/fbank/cv-${lang}_cuts_invalidated.jsonl.gz
    touch data/${lang}/fbank/.cv-${lang}_invalidated.done
  fi
fi

if [ $stage -le 8 ] && [ $stop_stage -ge 8 ]; then
  log "Stage 8: Compute fbank for musan"
  mkdir -p data/fbank
  if [ ! -e data/fbank/.musan.done ]; then
    ./local/compute_fbank_musan.py
    touch data/fbank/.musan.done
  fi
fi

if [ $stage -le 9 ] && [ $stop_stage -ge 9 ]; then
  if [ $lang == "yue" ] || [ $lang == "zh-TW" ] || [ $lang == "zh-CN" ] || [ $lang == "zh-HK" ]; then
    log "Stage 9: Prepare Char based lang"
    lang_dir=data/${lang}/lang_char/
    mkdir -p $lang_dir

    if [ ! -f $lang_dir/transcript_words.txt ]; then
        log "Generate data for lang preparation"

        # Prepare text.
        # Note: in Linux, you can install jq with the following command:
        # 1. wget -O jq https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64
        # 2. chmod +x ./jq
        # 3. cp jq /usr/bin
        if [ $use_validated = true ]; then
          gunzip -c data/${lang}/manifests/cv-${lang}_supervisions_validated.jsonl.gz \
            | jq '.text' | sed 's/"//g' >> $lang_dir/text
        else
          gunzip -c data/${lang}/manifests/cv-${lang}_supervisions_train.jsonl.gz \
            | jq '.text' | sed 's/"//g' > $lang_dir/text
        fi
        
        if [ $use_invalidated = true ]; then
          gunzip -c data/${lang}/manifests/cv-${lang}_supervisions_invalidated.jsonl.gz \
            | jq '.text' | sed 's/"//g' >> $lang_dir/text
        fi

        if [ $lang == "yue" ] || [ $lang == "zh-HK" ]; then
          # Get words.txt and words_no_ids.txt
          ./local/word_segment_yue.py \
            --input-file $lang_dir/text \
            --output-dir $lang_dir \
            --lang $lang

          mv $lang_dir/text $lang_dir/_text
          cp $lang_dir/transcript_words.txt $lang_dir/text

          if [ ! -f $lang_dir/tokens.txt ]; then
            ./local/prepare_char.py --lang-dir $lang_dir
          fi
        else
          log "word_segment_${lang}.py not implemented yet"
          exit 1
        fi
      fi
  else
    log "Stage 9: Prepare BPE based lang"
    for vocab_size in ${vocab_sizes[@]}; do
      lang_dir=data/${lang}/lang_bpe_${vocab_size}
      mkdir -p $lang_dir

      if [ ! -f $lang_dir/transcript_words.txt ]; then
        log "Generate data for BPE training"
        file=$(
          find "data/${lang}/fbank/cv-${lang}_cuts_train.jsonl.gz"
        )
        
        echo $file
        # Prepare text.
        # Note: in Linux, you can install jq with the following command:
        # 1. wget -O jq https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64
        # 2. chmod +x ./jq
        # 3. cp jq /usr/bin
        #gunzip -c ${file} \
        #  | jq '.text' | sed 's/"//g' > $lang_dir/transcript_words.txt
          
        gunzip -c ${file} \
          | jq ".supervisions[0].text" | sed 's/"//g' > $lang_dir/transcript_words.txt
          
          

        # Ensure space only appears once
        sed -i 's/\t/ /g' $lang_dir/transcript_words.txt
        sed -i 's/[ ][ ]*/ /g' $lang_dir/transcript_words.txt
      fi

      if [ ! -f $lang_dir/words.txt ]; then
        cat $lang_dir/transcript_words.txt | sed 's/ /\n/g' \
          | sort -u | sed '/^$/d' > $lang_dir/words.txt
        (echo '!SIL'; echo '<SPOKEN_NOISE>'; echo '<UNK>'; ) |
          cat - $lang_dir/words.txt | sort | uniq | awk '
          BEGIN {
            print "<eps> 0";
          }
          {
            if ($1 == "<s>") {
              print "<s> is in the vocabulary!" | "cat 1>&2"
              exit 1;
            }
            if ($1 == "</s>") {
              print "</s> is in the vocabulary!" | "cat 1>&2"
              exit 1;
            }
            printf("%s %d\n", $1, NR);
          }
          END {
            printf("#0 %d\n", NR+1);
            printf("<s> %d\n", NR+2);
            printf("</s> %d\n", NR+3);
          }' > $lang_dir/words || exit 1;
        mv $lang_dir/words $lang_dir/words.txt
      fi

      if [ ! -f $lang_dir/bpe.model ]; then
        ./local/train_bpe_model.py \
          --lang-dir $lang_dir \
          --vocab-size $vocab_size \
          --transcript $lang_dir/transcript_words.txt
      fi

      if [ ! -f $lang_dir/L_disambig.pt ]; then
        ./local/prepare_lang_bpe.py --lang-dir $lang_dir

        log "Validating $lang_dir/lexicon.txt"
        ./local/validate_bpe_lexicon.py \
          --lexicon $lang_dir/lexicon.txt \
          --bpe-model $lang_dir/bpe.model
      fi

      if [ ! -f $lang_dir/L.fst ]; then
        log "Converting L.pt to L.fst"
        ./shared/convert-k2-to-openfst.py \
          --olabels aux_labels \
          $lang_dir/L.pt \
          $lang_dir/L.fst
      fi

      if [ ! -f $lang_dir/L_disambig.fst ]; then
        log "Converting L_disambig.pt to L_disambig.fst"
        ./shared/convert-k2-to-openfst.py \
          --olabels aux_labels \
          $lang_dir/L_disambig.pt \
          $lang_dir/L_disambig.fst
      fi
    done
  fi
fi

if [ $stage -le 10 ] && [ $stop_stage -ge 10 ]; then
  log "Stage 10: Prepare G"
  # We assume you have install kaldilm, if not, please install
  # it using: pip install kaldilm

  if [ $lang == "yue" ] || [ $lang == "zh-TW" ] || [ $lang == "zh-CN" ] || [ $lang == "zh-HK" ]; then
    lang_dir=data/${lang}/lang_char
    mkdir -p $lang_dir/lm

    for ngram in 3 ; do
        if [ ! -f $lang_dir/lm/${ngram}-gram.unpruned.arpa ]; then
          ./shared/make_kn_lm.py \
            -ngram-order ${ngram} \
            -text $lang_dir/transcript_words.txt \
            -lm $lang_dir/lm/${ngram}gram.unpruned.arpa
        fi

        if [ ! -f $lang_dir/lm/G_${ngram}_gram_char.fst.txt ]; then
          python3 -m kaldilm \
            --read-symbol-table="$lang_dir/words.txt" \
            --disambig-symbol='#0' \
            --max-order=${ngram} \
            $lang_dir/lm/${ngram}gram.unpruned.arpa \
              > $lang_dir/lm/G_${ngram}_gram_char.fst.txt
        fi

        if [ ! -f $lang_dir/lm/HLG.fst ]; then
          ./local/prepare_lang_fst.py \
            --lang-dir $lang_dir \
            --ngram-G $lang_dir/lm/G_${ngram}_gram_char.fst.txt
        fi
      done
  else
    for vocab_size in ${vocab_sizes[@]}; do
      lang_dir=data/${lang}/lang_bpe_${vocab_size}
      mkdir -p $lang_dir/lm
      #3-gram used in building HLG, 4-gram used for LM rescoring
      for ngram in 3 4; do
        if [ ! -f $lang_dir/lm/${ngram}gram.arpa ]; then
          ./shared/make_kn_lm.py \
            -ngram-order ${ngram} \
            -text $lang_dir/transcript_words.txt \
            -lm $lang_dir/lm/${ngram}gram.arpa
        fi

        if [ ! -f $lang_dir/lm/${ngram}gram.fst.txt ]; then
          python3 -m kaldilm \
            --read-symbol-table="$lang_dir/words.txt" \
            --disambig-symbol='#0' \
            --max-order=${ngram} \
            $lang_dir/lm/${ngram}gram.arpa > $lang_dir/lm/G_${ngram}_gram.fst.txt
        fi
      done
    done
  fi
fi

if [ $stage -le 11 ] && [ $stop_stage -ge 11 ]; then
  log "Stage 11: Compile HLG"

  if [ $lang == "yue" ] || [ $lang == "zh-TW" ] || [ $lang == "zh-CN" ] || [ $lang == "zh-HK" ]; then
    lang_dir=data/${lang}/lang_char
    for ngram in 3 ; do
      if [ ! -f $lang_dir/lm/HLG_${ngram}.fst ]; then
        ./local/compile_hlg.py --lang-dir $lang_dir --lm G_${ngram}_gram_char
      fi
    done
  else
    for vocab_size in ${vocab_sizes[@]}; do
      lang_dir=data/${lang}/lang_bpe_${vocab_size}
      ./local/compile_hlg.py --lang-dir $lang_dir

      # Note If ./local/compile_hlg.py throws OOM,
      # please switch to the following command
      #
      # ./local/compile_hlg_using_openfst.py --lang-dir $lang_dir
    done
  fi
fi

# Compile LG for RNN-T fast_beam_search decoding
if [ $stage -le 12 ] && [ $stop_stage -ge 12 ]; then
  log "Stage 12: Compile LG"

  if [ $lang == "yue" ] || [ $lang == "zh-TW" ] || [ $lang == "zh-CN" ] || [ $lang == "zh-HK" ]; then
    lang_dir=data/${lang}/lang_char
    for ngram in 3 ; do
      if [ ! -f $lang_dir/lm/LG_${ngram}.fst ]; then
        ./local/compile_lg.py --lang-dir $lang_dir --lm G_${ngram}_gram_char
      fi
    done
  else 
    for vocab_size in ${vocab_sizes[@]}; do
      lang_dir=data/${lang}/lang_bpe_${vocab_size}
      ./local/compile_lg.py --lang-dir $lang_dir
    done
  fi
fi
