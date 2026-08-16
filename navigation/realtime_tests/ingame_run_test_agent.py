#!/usr/bin/env python3
"""Focus Minecraft and type into an open CC terminal (or after user faces computer).

Usage:
  ingame_run_test_agent.py              # type: test_agent\\n
  ingame_run_test_agent.py --terminate  # Ctrl+T then test_agent\\n
  ingame_run_test_agent.py --cmd 'shell.run("test_agent")'
"""
from __future__ import annotations
import argparse, subprocess, time, sys

def wmctrl_focus(substr: str) -> bool:
    out = subprocess.check_output(["wmctrl", "-l"], text=True)
    wid = None
    for line in out.splitlines():
        if substr.lower() in line.lower():
            wid = line.split()[0]
            break
    if not wid:
        print(f"window not found matching {substr!r}", file=sys.stderr)
        return False
    subprocess.check_call(["wmctrl", "-i", "-a", wid])
    time.sleep(0.35)
    return True

def type_text(text: str, pause: float = 0.03) -> None:
    from Xlib import X, XK, display
    from Xlib.ext import xtest
    d = display.Display()
    # special names
    special = {
        "\n": "Return",
        "\t": "Tab",
        " ": "space",
    }
    for ch in text:
        if ch in special:
            ks = XK.string_to_keysym(special[ch])
        elif ch.isupper() or ch in '~!@#$%^&*()_+{}|:"<>?':
            # shift+key for uppercase/simple punct — limited
            ks = XK.string_to_keysym(ch.lower()) if ch.isalpha() else XK.string_to_keysym(ch)
            shift = d.keysym_to_keycode(XK.string_to_keysym("Shift_L"))
            code = d.keysym_to_keycode(ks)
            xtest.fake_input(d, X.KeyPress, shift)
            xtest.fake_input(d, X.KeyPress, code)
            d.sync()
            xtest.fake_input(d, X.KeyRelease, code)
            xtest.fake_input(d, X.KeyRelease, shift)
            d.sync()
            time.sleep(pause)
            continue
        else:
            ks = XK.string_to_keysym(ch)
        if not ks:
            print(f"skip unknown char {ch!r}", file=sys.stderr)
            continue
        code = d.keysym_to_keycode(ks)
        if not code:
            print(f"no keycode for {ch!r}", file=sys.stderr)
            continue
        xtest.fake_input(d, X.KeyPress, code)
        d.sync()
        xtest.fake_input(d, X.KeyRelease, code)
        d.sync()
        time.sleep(pause)

def key_combo(*names: str) -> None:
    from Xlib import X, XK, display
    from Xlib.ext import xtest
    d = display.Display()
    codes = []
    for n in names:
        ks = XK.string_to_keysym(n)
        codes.append(d.keysym_to_keycode(ks))
    for c in codes:
        xtest.fake_input(d, X.KeyPress, c)
        d.sync()
    time.sleep(0.05)
    for c in reversed(codes):
        xtest.fake_input(d, X.KeyRelease, c)
        d.sync()

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--terminate", action="store_true", help="Ctrl+T before command")
    ap.add_argument("--cmd", default="test_agent", help="text to type then Enter")
    ap.add_argument("--right-click", action="store_true", help="send mouse right-click (open computer if looking at it)")
    args = ap.parse_args()
    if not wmctrl_focus("Minecraft NeoForge"):
        return 2
    time.sleep(0.2)
    if args.right_click:
        from Xlib import X, display
        from Xlib.ext import xtest
        d = display.Display()
        # Button 3 = right
        xtest.fake_input(d, X.ButtonPress, 3)
        d.sync()
        time.sleep(0.05)
        xtest.fake_input(d, X.ButtonRelease, 3)
        d.sync()
        time.sleep(0.5)
    if args.terminate:
        key_combo("Control_L", "t")
        time.sleep(0.4)
    cmd = args.cmd if args.cmd.endswith("\n") else args.cmd + "\n"
    type_text(cmd)
    print("typed:", repr(cmd))
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
