# ETORRENT

ETORRENT is a bittorrent client written in Erlang. The focus is on
robustness and scalability in number of torrents rather than in pure
speed. ETORRENT is mostly meant for unattended operation, where one
just specifies what files to download and gets a notification when
they are.

ETORRENT was mostly conceived as an experiment in how easy it would be
to write a bittorrent client in Erlang. The hypothesis is that the
code will be cleaner and smaller than comparative bittorrent clients.

Note that the code is not yet battle scarred. It has not stood up to the
testing of time and as such, it will fail - sometimes in nasty ways and
maybe as a bad p2p citizen. Hence, you should put restraint in using it
unless you are able to fix eventual problems. If you've noticed any bad
behavior it is definitely a bug and should be reported as soon as possible
so we can get it away.

### Currently supported BEPs:

   * BEP 03 - The BitTorrent Protocol Specification.
   * BEP 04 - Known Number Allocations.
   * BEP 12 - Multitracker Metadata Extension.
   * BEP 23 - Tracker Returns Compact Peer Lists.

## GETTING STARTED

   0. `make compile` - this compiles the source code
   1. 'make rel' - this creates an embedded release in *rel/etorrent* which
      can subsequently be moved to a location at your leisure.
   2. edit *rel/etorrent/etc/app.config* - there are a number of directories
      which must be set in order to make the system work.
   3. check *rel/etorrent/etc/vm.args* - Erlang args to supply
   4. If you enabled the webui, check *rel/etorrent/etc/webui.config*
   5. run 'rel/etorrent/bin/etorrent console'
   6. drop a .torrent file in the watched dir and see what happens.
   7. call etorrent:help(). from the Erlang CLI to get a list of available
      commands.
   8. If you enabled the webui, you can try browsing to its location. By default the location is 'http://localhost:8080'.

## ISSUES

Either mail them to jesper.louis.andersen@gmail.com (We are
currently lacking a mailing list) or use the issue tracker:

  http://github.com/jlouis/etorrent/issues

## Reading material for hacking Etorrent:

   - [Protocol specification - BEP0003](http://www.bittorrent.org/beps/bep_0003.html):
     This is the original protocol specification, tracked into the BEP
     process. It is worth reading because it explains the general overview
     and the precision with which the original protocol was written down.

   - [Bittorrent Enhancement Process - BEP0000](http://www.bittorrent.org/beps/bep_0000.html)
     The BEP process is an official process for adding extensions on top of
     the BitTorrent protocol. It allows implementors to mix and match the
     extensions making sense for their client and it allows people to
     discuss extensions publicly in a forum. It also provisions for the
     deprecation of certain features in the long run as they prove to be of
     less value.

   - [wiki.theory.org](http://wiki.theory.org/Main_Page)
     An alternative description of the protocol. This description is in
     general much more detailed than the BEP structure. It is worth a read
     because it acts somewhat as a historic remark and a side channel. Note
     that there are some commentary on these pages which can be disputed
     quite a lot.

; vim: filetype=none tw=76 expandtab
