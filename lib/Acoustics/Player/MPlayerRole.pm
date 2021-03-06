package Acoustics::Player::MPlayerRole;

use strict;
use warnings;

use Moose;
use IPC::Open2 'open2';

with 'Acoustics::Player';

# Acoustics::Player helps us with the database stuff
sub start {
	my $acoustics = shift;
	my $song_end_reason = 'complete';

	local $SIG{CHLD} = 'IGNORE'; # we don't want zombies on our lawn
	local $SIG{HUP}  = 'IGNORE'; # ignore extra skip requests
	# process stop requests
	local $SIG{TERM} = local $SIG{INT} = sub {
		$song_end_reason = 'stop';
		return;
	};
	local $SIG{USR1} = $SIG{USR2} = sub {
		print STDERR "Not implemented! Go bug avuserow to do so!\n";
		return;
	};
	while ($song_end_reason ne 'stop') {
		$song_end_reason = 'complete';
		my $song = get_song_to_play($acoustics);

		my $pid = open2(my $child_out, my $child_in,
			'mplayer', '-slave', '-quiet',
			# TODO: other args
			$song->{path});

		# TODO: figure out a better way to do signal stuff with a role
		local $SIG{USR2} = sub {
			if ($child_in && kill 0, $pid) {
				print STDERR "(un)pausing song!\n";
				print $child_in "pause\n";
			}
			return;
		};
		local $SIG{HUP} = sub {
			$song_end_reason = 'skip';
			if ($child_in && kill 0, $pid) {
				print $child_in "quit\n";
			}
			return;
		};

		local $SIG{__DIE__} = sub {
			# we're toast! :(
			require Carp;
			print Carp::longmess(@_);
			print $child_in "quit\n";
		};
		local $SIG{TERM} = local $SIG{INT} = sub {
			print STDERR "exiting!\n";
			$song_end_reason = 'stop';
			if ($child_in && kill 0, $pid) {
				print STDERR "quitting!\n";
				print $child_in "quit\n";
			}
			return;
		};

		begin_song($acoustics, $song);

		# block on the mplayer process
		while (<$child_out>) {}

		close $child_out;
		close $child_in;

		finish_song($acoustics, $song_end_reason, $song);
	}
}

sub stop {
	my $class = shift;
	my $acoustics = shift;
	send_signal($acoustics, 'INT');
}

sub pause {
	my $class     = shift;
	my $acoustics = shift;
	send_signal($acoustics, 'USR2');
}

sub skip {
	my $class = shift;
	my $acoustics = shift;
	send_signal($acoustics, 'HUP');
}

sub send_signal {
	my $acoustics = shift;
	my $signal    = shift;
	my $player = $acoustics->query(
		'select_players', {player_id => $acoustics->player_id},
	);

	if (!defined($player->{local_id})) {
		die "Tried to send signal $signal to a player that isn't running.";
	}
	my $success = kill $signal => $player->{local_id};

	if ($success) {
		#remark "Sent $signal to $player->{local_id}";
	} else {
		die "Sending $signal to $player->{local_id} failed: $!";
	}

	return 0;
}


1;
