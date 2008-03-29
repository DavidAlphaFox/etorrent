-record(tracking_map, {filename,
		       supervisor_pid}).

-record(info_hash, {info_hash,
		    storer_pid,
		    state}).


-record(peer_info, {id,
		    uploaded,
		    downloaded,
		    interested,
		    remote_choking,
		    optimistic_unchoke}).

-record(peer_map, {pid,
		   ip,
		   port,
		   info_hash}).

-record(peer,     {map,
		   info}).

-record(file_access, {pid,
		      piece_number,
		      hash,
		      files,
		      state}).

