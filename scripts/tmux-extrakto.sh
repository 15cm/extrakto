#!/bin/bash

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
LAST_ACTIVE_PANE=$1
source "$CURRENT_DIR/helpers.sh"
extrakto="$CURRENT_DIR/../extrakto.py"

# options
grab_area=$(get_option "@extrakto_grab_area")
extrakto_opts=$(get_option "@extrakto_opts")
clip_tool=$(get_option "@extrakto_clip_tool")
fzf_tool=$(get_option "@extrakto_fzf_tool")
open_tool=$(get_option "@extrakto_open_tool")
browser_tool=$(get_option "@extrakto_browser_tool")
fzf_options=$(get_option "@extrakto_fzf_options")
split_size=$(get_option "@extrakto_split_size")

capture_pane_start=$(get_capture_pane_start "$grab_area")
original_grab_area=${grab_area}  # keep this so we can cycle between alternatives on fzf

extrakto_opt_arr=($(echo $extrakto_opts))
extrakto_opt_index=0

if [[ "$clip_tool" == "auto" ]]; then
  case "`uname`" in
    'Linux')
      if [[ $(cat /proc/sys/kernel/osrelease) =~ 'Microsoft' ]]; then
        clip_tool='clip.exe'
      else
        clip_tool='xclip -i -selection clipboard >/dev/null'
      fi
      ;;
    'Darwin') clip_tool='pbcopy' ;;
    *) ;;
  esac
fi

if [[ "$open_tool" == "auto" ]]; then
  case "`uname`" in
    'Linux') open_tool='xdg-open >/dev/null' ;;
    'Darwin') open_tool='open' ;;
    *) open_tool='' ;;
  esac
fi

if [[ -z $EDITOR ]]; then
  # fallback
  editor="vi"
else
  editor="$EDITOR"
fi

function capture_panes() {
  if [[ $grab_area =~ ^window\  ]]; then
    for pane in $(tmux list-panes -F "#{pane_active}:#{pane_id}"); do
      if [[ $pane =~ ^0: && ${pane:2} != ${LAST_ACTIVE_PANE} ]]; then
        local captured+=$(tmux capture-pane -pJS ${capture_pane_start} -t ${pane:2})
        local captured+=$'\n'
      fi
    done
  fi
  local captured+=$(tmux capture-pane -pJS ${capture_pane_start} -t !)

  echo "$captured"
}

function capture() {
  extrakto_opt=${extrakto_opt_arr[$extrakto_opt_index]}

  header="enter=insert, ctrl-y=copy"
  if [ -n "$open_tool" ]; then header="$header, ctrl-o=open"; fi
  header="$header, ctrl-e=edit"
  header="$header, ctrl-f=toggle filter [$extrakto_opt], ctrl-l=grab area [$grab_area]"
  if [ -n "$browser_tool" ]; then header="$header, ctrl-u=open in browser"; fi

  case $extrakto_opt in
    'path/url') extrakto_flags='pu' ;;
    'lines') extrakto_flags='l' ;;
    *) extrakto_flags='w' ;;
  esac

  # for troubleshooting add
  # tee /tmp/stageN | \
  # between the commands
  sel=$(capture_panes | \
    $extrakto -r$extrakto_flags | \
    (read line && (echo $line; cat) || echo NO MATCH - use a different filter) | \
    $fzf_tool $fzf_options \
      --header="$header" \
      --expect=enter,ctrl-y,ctrl-e,ctrl-f,ctrl-l,ctrl-o,ctrl-c,ctrl-u,esc \
      --tiebreak=index)

  if [ $? -gt 0 ]; then
    echo "error: unable to extract - check/report errors above"
    echo "You can also set the fzf path in options (see readme)."
    read
    exit
  fi

  key=$(head -1 <<< "$sel")
  text=$(tail -n +2 <<< "$sel" | tr '\n' ' ' | sed 's/[[:space:]]\{1,\}/ /g')

  case $key in

    enter)
      tmux set-buffer -- "$text"
      tmux paste-buffer -t !
      ;;

    ctrl-y)
      tmux set-buffer -- "$text"
      # run in background as xclip won't work otherwise
      tmux run-shell -b "tmux show-buffer|$clip_tool"
      ;;


    ctrl-f)
      (( extrakto_opt_index++ ))
      [ $extrakto_opt_index -eq ${#extrakto_opt_arr[@]} ] && extrakto_opt_index=0
      capture
      ;;

    ctrl-l)
      # cycle between options like this:
      # recent -> full -> window recent -> window full -> custom (if any) -> recent ...
      if [[ $grab_area == "recent" ]]; then
          grab_area="window recent"
      elif [[ $grab_area == "window recent" ]]; then
          grab_area="full"
      elif [[ $grab_area == "full" ]]; then
          grab_area="window full"
      elif [[ $grab_area == "window full" ]]; then
          grab_area="recent"

          if [[ ! "$original_grab_area" =~ ^(window )?(recent|full)$ ]]; then
              grab_area="$original_grab_area"
          fi
      else
          grab_area="recent"
      fi

      capture_pane_start=$(get_capture_pane_start "$grab_area")

      capture
      ;;

    ctrl-o)
      if [ -n "$open_tool" ]; then
        tmux run-shell -b "cd $PWD; $open_tool '$text'"
      else
        capture
      fi
      ;;

    ctrl-e)
      tmux send-keys -t ! "$editor -- $text" 'C-m'
      ;;

    ctrl-u)
      if [ -n "$browser_tool" ]; then
        tmux run-shell -b "$browser_tool '$text'"
      else
        capture
      fi
      ;;
  esac
}

# check terminal size, zoom pane if too small
lines=$(tput lines)
if [ $lines -lt $split_size ]; then
  tmux resize-pane -Z
fi

capture
