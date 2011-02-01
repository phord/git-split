#!/bin/bash

# git-split.sh - hordp@cisco.com
#
# A script to transmogrify git repositories in various ways
# using git filter-branch and a clever gitignore-like keep/delete
# syntax. This attempt reads a single conf file and outputs
# different targets to the output.
#

#_____________________________________________________________________________
#                                                                        SETUP

COLOR_START=`echo -e '\033['`
COLOR_END='m'

RED=`echo -e '\033[31m'`
GREEN=`echo -e '\033[32m'`
NORMAL=`echo -e '\033[0m'`

TMP_DIR=/tmp

#_____________________________________________________________________________
#                                                                      CMDLINE

# Stop on errors
set -e

# Uncomment for script tracing
# set -x

verbose()
{
  if [[ $VERBOSE > 0 ]] ; then
    echo "$@"
  fi
}

usage()
{
cat << EOF
usage: $0 options <config-file> [<repository>]

Divides a git repository into one or more new repositories by cloning the original repository
and removing unwanted files from the new repository(ies)

OPTIONS:
   -h        Show this message
   -f        Force overwrite of output repositories if they exist
   -D        DryRun mode: list which files will be removed/retained
   -i        Specify input repository (in options instead of at end)
   -t path   Specify target path
   -v        Verbose

   <config-file>   Config settings; a mostly-.gitignore-style list of files to keep/remove
   <repository>    Source repo. Optional. May be specified in the config file.
EOF
}

SOURCE_REPO=
FORCE=0
VERBOSE=0
DRYRUN=0
TESTSPLIT=0
SOURCE_MATCH=
TARGET_PATH=

options()
{
    # Handles options received from multiple command lines

    OPTIND=1
    CONFIG_FILES=
    while [ $OPTIND -le $# ] ; do
      while getopts “hfi:t:TDv” OPTION
      do
         case $OPTION in
             h)
                 usage
                 exit 1
                 ;;
             t)
    	     TARGET_PATH="$OPTARG"
                 ;;
             i)
    	     SOURCE_REPO="$OPTARG"
                 ;;
             f)
    	     FORCE=1
                 ;;
             T)
                 # Undocumented experimental option.  Only modifies workdir in new repo for fast testing.
                 TESTSPLIT=1
                 ;;
             D)
                 DRYRUN=1
                 ;;
             v)
                 VERBOSE=$(( $VERBOSE+1 ))
                 ;;
             ?)
                 usage
                 exit
                 ;;
         esac
      done

      if [ $OPTIND -le $# ] ; then
          shift $(( OPTIND-1 ))
          CONFIG_FILES="${CONFIG_FILES} $1"
          shift
          OPTIND=1
      fi
    done

export SOURCE_REPO
export VERBOSE
export DRYRUN
export TESTSPLIT
export TARGET_PATH
export CONFIG_FILES
}

# Parse the command-line options
options $@

# Source file is required
if [[ -z "$CONFIG_FILES" ]] ; then
  usage
  exit
fi

if [[ ! -z "$CONFIG_FILES" ]] ; then
  SOURCE_MATCH="$CONFIG_FILES"
fi

for SOURCE_MATCH in $CONFIG_FILES ; do
    # Required options: complain if not on command line or in source file
    if [[ -z $SOURCE_REPO ]]
    then
         usage
         exit 1
    fi

    if [[ $VERBOSE > 0 ]] ; then
      echo "SOURCE_REPO=$SOURCE_REPO"
      echo "SOURCE_MATCH=$SOURCE_MATCH"
      echo "TARGET_PATH=$TARGET_PATH"
      echo "VERBOSE=$VERBOSE"
      echo "DRYRUN=$DRYRUN"
      echo "TESTSPLIT=$TESTSPLIT"
      echo "-------------------------------"
    fi

    #_____________________________________________________________________________
    #                                                                     VALIDATE
    if ! [ -e "$SOURCE_REPO" ] ; then
      echo "Warning: Source repository '$SOURCE_REPO' not found"
    fi

    if ! [ -e "$SOURCE_MATCH" ] ; then
      echo "Error: '$SOURCE_MATCH' not found"
      usage
      exit 1
    fi

    #_____________________________________________________________________________
    #                                                               PROCESS CONFIG

    if [[ $VERBOSE > 1 ]] ; then
    	echo "Extra verbose..."
    	set -x
    fi

    verbose "Converting $SOURCE_MATCH to a sed script"
    BASE_PATH="${TMP_DIR}/${SOURCE_MATCH#*/}"
    MATCH_FILE="${BASE_PATH}-match.sed"
    RAW_FILES="${BASE_PATH}-raw.txt"
    ALL_FILES="${BASE_PATH}-all.txt"

    if [ -z "$TARGET_PATH" ] ; then
      TARGET_PATH="."
    fi

    if ! [ -e "$TARGET_PATH" ] ; then
      mkdir -p "$TARGET_PATH"
    fi

    # Convert the input globs into a sed script
    cat $SOURCE_MATCH | sed -e '
    1i\
        x;s/.*/-/;x		# Pre-load hold buffer with "-" for "no-match"
    1i\
        /^$/d		# Skip blank lines in the files list
    1i\

    /^[ \t]*$/d

    s/^[ \t]*//		# Remove leading whitespace
    s/#.*//			# Remove comments
    s/[ \t]*$//		# Remove trailing whitespace
    /^!*$/d  		# Remove blank lines

    h			# copy buffer to hold buffer
    s/^\(!\)*\(!!\)*.*$/\1/	# collect odd leading ! if any
    x			# swap into hold buffer
    s/^![ \t]*//		# and remove from pattern buffer

    /^--*>[ \t]*/ {		# --> Pusher
    # When we get here, hold buffer is loaded with + or - indicating keep or toss.
    # If its a keeper we need to put our section tag on it.
    # x			# Swap +/- into pattern space
    # \\|^[+]| {		# If its a match
    #   a\			# append the tag to it
    # foo
    # G			# Append matched string to this one
    #  s/\n/\t/g		# Replace LF with TABs
    # p;d			# Print the string and be done
    # }
      s/--*>[ \t]*//	# Dump the prefix
      s!.*!#-- Push matches to &\nx\n  \\|^[+]| {\n    s/.*/&/\n    G\n    s/\\n/\\t/g\n    p;d\n  }\nx!
      p;d
    }

    s-[.]-[.]-g    		# Convert . to [.] (extension marker, not any-char)
    s-[+]-[+]-g    		# Convert + to [+]

    s-\*-|-g   		# Temp: replace * with |
    s-||-.*-g		# Convert ** to path-spanning globber (.*)
    s-|-[^/]*-g		# Convert * to filename globber (^[/]*)

    s-^[^/]-^\\(.*/\\)*&-	# interpret paths:  bar/foo/ == ^(.*/)*bar/foo/, /bar/foo == /bar/foo
    s-[^/]$-&$-		# interpret paths:  bar/foo/ == ^(.*/)*bar/foo/, /bar/foo == /bar/foo$
    s-^/-^-     		# Force ^/ paths to match from start-of-line

    # Input line is converted to a glob matcher now.  Emit as matcher address to next-sed:
    s-.*-\\|&| {-p

    x 			# Recover negation operator from hold buffer
    s|!|-|;s|^$|+| 		# and replace with + or -
    s/./\tx;s|.*|&|;x\n\t}/	# Put mark ("+" or "-") in hold buffer of next-sed

    ' > $MATCH_FILE

    #_____________________________________________________________________________
    #                                                                    GET FILES
    verbose "Gathering file list from $SOURCE_REPO"

    if [[ $TESTSPLIT == 0 ]] ; then
      # Grab all the filenames from the repo
      GIT_DIR=$SOURCE_REPO git log --pretty=format: --name-only --diff-filter=A --all | sort - | uniq > $RAW_FILES
    else
      # Grab all the current filenames from the repo
      GIT_DIR=$SOURCE_REPO git ls-tree -r --name-only HEAD| sort - | uniq > $RAW_FILES
    fi
    # Flag each file for keep/no-keep
    sed -f $MATCH_FILE < $RAW_FILES > $ALL_FILES


    #_____________________________________________________________________________
    #                                                                SPLIT RESULTS
    verbose "Splitting into groups"

    TARGETS=$(cut "-d	" $ALL_FILES -f1 | sort - | uniq |grep -e "^[^-]")

    # Create the TARGET files for each new repository
    for A in $TARGETS ; do
    	TARG="$TARGET_PATH/$A.gitrm"
    	verbose "   --> $TARG "
    	sed -n -e "/^$A\t/d" -e "s/..*\t/0 0000000000000000000000000000000000000000\t/p" $ALL_FILES > $TARG
    done

    if [[ $DRYRUN > 0 ]] ; then
      # If dry-run, colorize the file sets here and display them
      colors=( 31 32 33 35 36 37 41 42 47 46 45 34 )

      # TODO: Option to also list "-targets"
      grep -e "^[^-]" $ALL_FILES | sed $(
        i=0
        for A in $TARGETS ; do
          echo "-e /^$A\t/s/^/${COLOR_START}${colors[$i]}${COLOR_END}/"
          i=$(( $i+1 ))
        done
      ) - | less -R -
    fi


    #_____________________________________________________________________________
    #                                                                       REWORK
    if [[ $DRYRUN == 0 ]] ; then
        TMPSOURCE="$TARGET_PATH/.tmp_divide"
        rm -rf $TMPSOURCE
        if [[ $TESTSPLIT == 0 ]] ; then
          # Use --mirror here so I can be sure to get everything (remote branches) as a base
          git clone --mirror "$SOURCE_REPO" "$TMPSOURCE"
        else
           # Clone working directories here
           git clone "$SOURCE_REPO" "$TMPSOURCE"
	   rm -rf "$TMPSOURCE/.git"
        fi

	FAIL=0
        for TARG in $TARGETS ; do
	  TARGET_REPO=$TARGET_PATH/${TARG}.git
    	  if [[ $TESTSPLIT > 0 ]] ; then
    	    TARGET_REPO=$TARGET_PATH/${TARG}
	  fi
          if [ -e $(readlink -f $TARGET_REPO) ] ; then
    	    if [[ $(readlink -f $TARGET_REPO) != $(readlink -f $SOURCE_REPO) ]] ; then
    	      if [[ $FORCE > 0 ]] ; then
    	          rm -rf "$TARGET_REPO"
    	      else
      		echo "Warning: $TARGET_REPO already exists.  Use -f to force overwrite."
		FAIL=1
    	      fi
            fi
          fi
        done
	if [[ $FAIL == 0 ]] ; then
          for TARG in $TARGETS ; do
	    TARGET_REPO=$TARGET_PATH/${TARG}.git
    	    if [[ $TESTSPLIT > 0 ]] ; then
    	      TARGET_REPO=$TARGET_PATH/${TARG}
	    fi
    	    if [[ $(readlink -f $TARGET_REPO) != $(readlink -f $SOURCE_REPO) ]] ; then
	      echo "Cloning into $TARGET_REPO"
	      cp -alT "$TMPSOURCE" "$TARGET_REPO"
	    fi
          done
    	fi
        rm -rf $TMPSOURCE
	if [[ $FAIL > 0 ]] ; then
	  exit
	fi

      for TARG in $TARGETS ; do
    	FILTER=$(readlink -f $TARGET_PATH/${TARG}.gitrm )
    	TARGET_REPO=$(readlink -f $TARGET_PATH/${TARG}.git)
    	if [[ $TESTSPLIT == 0 ]] ; then
    	  verbose "Removing files from $TARGET_REPO  ($FILTER)"
    	  GIT_DIR=$TARGET_REPO git filter-branch -f --index-filter "git update-index --force-remove --index-info < $FILTER" \
    		--remap-to-ancestor --prune-empty --tag-name-filter cat -- --all
    	  verbose "Cleaning up old objects"
     	  rm -rf $TARGET_REPO/refs/original
    	  GIT_DIR=$TARGET_REPO git reflog expire --expire=now --all
    	  GIT_DIR=$TARGET_REPO git gc --prune=now
	else
    	  verbose "Removing files from ${TARGET_REPO%.git}  ($FILTER)"
    	  pushd ${TARGET_REPO%.git}
	    cut '-d	' -f2 $FILTER | xargs -i rm -f "{}"
	    find -depth -type d -empty -exec rmdir "{}" \;
	  popd
	fi

      done

        # Display the resulting repository sizes
        du -lsh $(
    	echo "$SOURCE_REPO"
            for TARG in $TARGETS ; do
    	       if [[ $TESTSPLIT == 0 ]] ; then
                 echo "$TARGET_PATH/${TARG}.git"
	       else
                 echo "$TARGET_PATH/${TARG}"
	       fi
            done
        ) | sort  -n
    fi
done


# TODO: Consider mode where we use this:
#   git --git-dir=../bootloader/bin.git/ ls-tree -r --full-name HEAD
# or   git ls-files --stage
# to get index, pipe it through a sed script that rewrites only-as-needed,
# and output to
#    git update-index --index-info

# This should allow us to rewrite filenames when needed, as well as delete filenames not wanted.



