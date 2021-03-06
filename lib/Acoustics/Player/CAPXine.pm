package Acoustics::Player::CAPXine;

use strict;
use warnings;

$|++;

use Log::Log4perl ':easy';
use IPC::Open2 'open2';
use Module::Load 'load';
use JSON::DWIW ();

use constant COMPONENT => 'player';

sub start {
	my $class     = shift;
	my $acoustics = shift;
	my $daemonize = shift;

	# FIXME: If you daemonize, you end up in / as the pwd
	# and if you don't, your pwd does not change
	# (as well as STD{IN,OUT,ERR} being closed/open)
	if ($daemonize) {
		$acoustics = daemonize($acoustics);
	}
	start_player($acoustics);
}

use POSIX 'setsid';
sub daemonize {
	my $acoustics = shift;

	my $pid = fork;
	if ($pid) {
		exit;
	} elsif ($pid == 0) {
		$acoustics = $acoustics->reinit;
		# The below is probably not needed and makes things more complicated
		# regarding paths
		#chdir '/'               or die "Can't chdir to /: $!";
		open STDIN, '<', '/dev/null' or die "Can't read /dev/null: $!";
		open STDOUT, '>', '/dev/null'
			or die "Can't write to /dev/null: $!";
		setsid                  or die "Can't start a new session: $!";
		#open STDERR, '>&', 'STDOUT' or die "Can't dup stdout: $!";
		return $acoustics;
	} else {
		ERROR "fork failed: $!";
	}
}

sub skip {
	my $class     = shift;
	my $acoustics = shift;
	$class->send_signal($acoustics, 'HUP');
}

sub stop {
	my $class     = shift;
	my $acoustics = shift;
	$class->send_signal($acoustics, 'INT');
}

sub zap {
	my $class = shift;
	my $acoustics = shift;
	my $dead_player_id = shift;
	# Don't do stupid things
	unless ($dead_player_id){
		ERROR "Blank player_id";
	} else {
		# KILL IT WITH FIRE
		$acoustics->query('delete_players', {player_id => $dead_player_id});
		INFO "Zapped $dead_player_id";
	}
}

sub volume {
	my $class     = shift;
	my $acoustics = shift;
	my $volume    = shift;

	if ($volume !~ /^\d+$/) {
		ERROR "volume must be a number, not something like '$volume'";
		return;
	}

	$acoustics->query(
		'update_players',
		{volume => $volume},
		{player_id => $acoustics->player_id},
	);
	my $player = $acoustics->query(
		'select_players', {player_id => $acoustics->player_id},
	);
	$class->send_signal($acoustics, 'USR1');
}

sub send_signal {
	my $class     = shift;
	my $acoustics = shift;
	my $signal    = shift;
	my $player = $acoustics->query(
		'select_players', {player_id => $acoustics->player_id},
	);

	my $success = kill $signal => $player->{local_id};

	if ($success) {
		INFO "Sent $signal to $player->{local_id}";
	} else {
		ERROR "Sending $signal to $player->{local_id} failed: $!";
	}

	return $success;
}

sub start_player {
	my $acoustics = shift;

	$acoustics->query('delete_players', {player_id => $acoustics->player_id});
	$acoustics->query('insert_players', {
		player_id => $acoustics->player_id,
		local_id  => $$,
		volume    => $acoustics->config->{player}{default_volume} || 20,
	});

	$acoustics->ext_hook(COMPONENT, 'start');

	local $SIG{TERM} = local $SIG{INT} = sub {
		WARN "Exiting player $$";
		$acoustics->query('delete_players', {player_id => $acoustics->player_id});
		exit;
	};
	local $SIG{HUP}  = 'IGNORE';
	local $SIG{CHLD} = 'IGNORE';
	local $SIG{USR1} = 'IGNORE';
	local $SIG{USR2} = 'IGNORE';

	$acoustics->get_current_song; # populate the playlist

	while (1) {
		run_player($acoustics);
	}
}

sub run_player {
	my $acoustics = shift;

	# Plan: run acoustics-cap-xine, feed it delicious songs.
	my($player_out, $player_in);
	my $pid = open2($player_out, $player_in,
		'/home/ak13/projects/custom-acoustics-player/cap');

	local $SIG{__DIE__} = local $SIG{TERM} = local $SIG{INT} = sub {
		print STDERR "got here!!\n";
		print $player_in "quit\n\n";
		$acoustics->query('delete_players',
			{player_id => $acoustics->player_id});
		exit 0;
	};
	my $song;
	while (<$player_out>) {
		my $song_start_time = time;
		# e.g. if the previous song has stopped
		if ($song) {
			$acoustics->queue->song_stop($song);
			$acoustics->query(delete_votes => {song_id => $song->{song_id}});
		}

		do {
			$song = $acoustics->get_current_song or
				$acoustics->query('select_songs', {online => 1},
					$acoustics->rand, 1);
		} until -e $song->{path};
		my $command = "next $song->{path}\n";
		print $player_in $command;
		print "sending $command";

		$acoustics->queue->song_start($song);

		$acoustics->query('update_players',
			{
				song_id    => $song->{song_id},
				song_start => $song_start_time,
				#queue_hint => scalar JSON::DWIW->new->to_json($queue_hint),
			},
			{player_id => $acoustics->player_id}
		);
	}
}

1;
