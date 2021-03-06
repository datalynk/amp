package Acoustics;

use strict;
use warnings;

our $VERSION = '0.01';

use Acoustics::Database;
use Moose;
use Module::Load 'load';
use DBI;
use Log::Log4perl;
use Date::Parse 'str2time';
use Config::Tiny;
use Storable 'dclone';
use Try::Tiny;
use JSON::DWIW ();

has 'db' => (is => 'ro', isa => 'DBI', handles => [qw(begin_work commit)]);
has 'config' => (is => 'ro', isa => 'Config::Tiny');
has 'querybook' => (is => 'ro', handles => ['query']);
has 'config_file' => (is => 'ro', isa => 'Str');
has 'player_id' => (is => 'rw', isa => 'Str', default => 'default player');
has 'queue' => (is => 'ro', isa => 'Acoustics::Queue');

# Logger configuration:
# - Print out all INFO and above messages to the screen
# - Write out all WARN and above messages to a logfile
my $log4perl_conf = q(
log4perl.logger = INFO, Screen, Logfile
log4perl.logger.Acoustics.Web = INFO, Weblogfile

# INFO messages
log4perl.filter.MatchInfo = Log::Log4perl::Filter::LevelRange
log4perl.filter.MatchInfo.LevelMin      = INFO
log4perl.filter.MatchInfo.AcceptOnMatch = true

# Error messages
log4perl.filter.MatchError = Log::Log4perl::Filter::LevelRange
log4perl.filter.MatchError.LevelMin      = WARN
log4perl.filter.MatchError.AcceptOnMatch = true

# INFO to Screen
log4perl.appender.Screen        = Log::Log4perl::Appender::ScreenColoredLevels
log4perl.appender.Screen.Filter = MatchInfo
log4perl.appender.Screen.layout = Log::Log4perl::Layout::PatternLayout
log4perl.appender.Screen.layout.ConversionPattern = %p %d %F{1} %L> %m %n

# ERROR to Logfile
log4perl.appender.Logfile          = Log::Log4perl::Appender::File
log4perl.appender.Logfile.Filter   = MatchError
log4perl.appender.Logfile.filename = /tmp/acoustics.log
log4perl.appender.Logfile.layout   = Log::Log4perl::Layout::PatternLayout
log4perl.appender.Logfile.layout.ConversionPattern = %p %d %F{1} %L> %m %n

# INFO to Weblogfile
log4perl.appender.Weblogfile          = Log::Log4perl::Appender::File
log4perl.appender.Weblogfile.Filter   = MatchInfo
log4perl.appender.Weblogfile.filename = /tmp/acoustics.log
log4perl.appender.Weblogfile.layout   = Log::Log4perl::Layout::PatternLayout
log4perl.appender.Weblogfile.layout.ConversionPattern = %p %d %F{1} %L> %m %n
);
Log::Log4perl::init(\$log4perl_conf);
my $logger = Log::Log4perl::get_logger;


sub BUILD {
	my $self = shift;

	unless ($self->{config_file}) {
		# if a file is not specified, then allow config files from the
		# environment, the home directory, the traditional conf directory (for
		# development), and finally system-wide in /etc/acoustics

		use Cwd 'cwd';
		my($base_acoustics_dir) = ($0 =~ m{^(.+)/[^/]+$});
		$base_acoustics_dir ||= '';
		if ($base_acoustics_dir !~ m{^/}) { # handle non-abs paths
			$base_acoustics_dir =~ s/^\.//; # handle './foo'
			$base_acoustics_dir = cwd() . $base_acoustics_dir;
		}
		# make this work for scripts in the root of the Acoustics dir, or for
		# ones in the bin subdirectory
		$base_acoustics_dir =~ s{bin/?$}{};
		my @AUTO_CONFIG_PATHS;
		push @AUTO_CONFIG_PATHS, $ENV{ACOUSTICS_CONFIG_FILE},
		push @AUTO_CONFIG_PATHS, $base_acoustics_dir . '/conf/acoustics.ini';
		push @AUTO_CONFIG_PATHS, cwd() . '/conf/acoustics.ini';

		my $homedir = glob('~') || $ENV{'HOME'};
		push @AUTO_CONFIG_PATHS, "$homedir/.acoustics.ini" if $homedir;
		push @AUTO_CONFIG_PATHS, '/etc/acoustics/acoustics.ini';

		for my $config (@AUTO_CONFIG_PATHS) {
			if (defined $config && -r $config) {
				$self->{config_file} = $config;
				last;
			}
		}
	}

	$self->{config} = Config::Tiny->read($self->config_file)
		or die "couldn't read config: \"" . $self->config_file . '"';

	$self->{db} = DBI->connect(
		$self->config->{database}{data_source},
		$self->config->{database}{user}, $self->config->{database}{pass},
		{RaiseError => 1, AutoCommit => 1},
	);
	$self->{querybook} = Acoustics::Database->new(
		db => [
			$self->config->{database}{data_source},
			$self->config->{database}{user}, $self->config->{database}{pass},
		],
		phrasebook => 'sql', # directory holding the dictionaries
	);
	$self->{db} = $self->{querybook}{db}; # backward compatibility

	$self->select_player($self->player_id);
	my $queue_class = $self->config->{player}{queue} || 'RoundRobin';
	$queue_class    = 'Acoustics::Queue::' . $queue_class;
	load $queue_class;
	$self->{queue} = $queue_class->new({acoustics => $self});
}

=head2 LOGGING

Acoustics has a minimalistic logging facility. It enables you to log fatal and non-fatal messages.

C<fatal()> and C<info()> both log a message, with an optional event parameter.
The message is presented to the user and stored in the database. The event
parameter is up to a given module to use to identify certain occurrences, and is
optional. Also optional is a hashref of arguments to determine certain logging
parameters. Currently, the only recognized value is "no_db". If set to true,
this will not be logged to the database.

C<fatal()> calls C<die> with the message at the end. C<info()> calls C<print>,
but only if C<Acoustics::Web> has not been loaded.

Also logged is the calling package, line number, and timestamp. This may change
to include additional debugging information.

TODO: Make it possible to opt in/out to certain event categories, to prevent
overly verbose information.

=head3 fatal('message', 'event', {args})
=head3 fatal('message', 'event')
=head3 fatal('message')

=cut

sub fatal {
	my $self = shift;
	my $mess = shift;
	$self->_log('fatal', $mess, [caller], @_);
}

=head3 info('message', 'event', {args})
=head3 info('message', 'event')
=head3 info('message')

=cut

sub info {
	my $self = shift;
	my $mess = shift;
	$self->_log('info', $mess, [caller], @_);
}

=head3 progress('message', 'event', {args})
=head3 progress('message', 'event')
=head3 progress('message')

Log a message at the "progress" level. Meant to allow long-running processes to
give user feedback in the web interface or elsewhere. This data is considered
public (such as scanning a music database).

=cut

sub progress {
	my $self = shift;
	my $mess = shift;
	$self->_log('progress', $mess, [caller], @_);
}

sub _log {
	my $self = shift;
	my $type = shift;
	my $mess = shift;
	my $call = shift;
	my $args = {};
	my $event = $type;

	for my $val (@_) {
		if (not ref $val) {
			# looks like an event string
			$event = $val;
		} elsif (ref $val eq 'HASH') {
			# args hash
			$args = $val;
		} else {
			die "unexpected value given to _log: $val";
		}
	}

	unless ($args->{no_db}) {
		try {
			$self->query('insert_logs', {
				message => $mess,
				time => time,
				filename => $call->[0],
				package => $call->[1],
				line => $call->[2],
				event => $event,
				type => $type,
			});
		} catch {
			$self->fatal("Could not insert log message into database. (Database)
				error is '$_'. Original message was '$mess'.", {no_db => 1});
		};
	}

	my $formatted = sprintf('%s: acoustics[%s:%s at %s]: %s: %s' . "\n",
		$type, $call->[0], $call->[2], scalar(localtime), $event, $mess,
	);
	if ($type eq 'fatal') {
		die $formatted;
	} elsif (not exists $INC{'Acoustics/Web.pm'}) { # FIXME: make more robust
		print $formatted;
	}
}

sub select_player {
	my $self   = shift;
	my $player = shift || '';

	my @players = split /\s*,\s*/, $self->config->{_}{players};

	if (grep {$_ eq $player} @players) {
		$self->config->{player} = $self->config->{'player.' . $player};
		$self->player_id($player);
	} else {
		$self->config->{player} = $self->config->{'player.' . $players[0]};
		$self->player_id($players[0]);
	}
}

=head2 JSON TOOLS

Currently we use JSON::DWIW for encoding/decoding, but this is likely to change. To help this, we have generic to_json and from_json routines.

=head3 to_json($data_structure)

=cut

sub to_json {
	my $self = shift;
	my $data = shift;

	return JSON::DWIW->new(
		{escape_multi_byte => 1, bad_char_policy => 'convert', pretty => 1}
	)->to_json($data);
}

sub from_json {
	my $self = shift;
	my $json = shift;

	return JSON::DWIW->new->from_json($json);
}

sub initdb_mysql {
	my $self = shift;
	my $db   = $self->db;

	$db->do("DROP TABLE IF EXISTS songs");
	$db->do("DROP TABLE IF EXISTS votes");
	$db->do("DROP TABLE IF EXISTS history");
	$db->do("DROP TABLE IF EXISTS players");
	$db->do("DROP TABLE IF EXISTS playlists");
	$db->do("DROP TABLE IF EXISTS playlist_contents");

	$db->do("CREATE TABLE songs (song_id INT UNSIGNED AUTO_INCREMENT, path
		VARCHAR(1024) NOT NULL, artist VARCHAR(256), album VARCHAR(256), title
		VARCHAR(256), length INT UNSIGNED NOT NULL, track INT UNSIGNED, online
		TINYINT(1) UNSIGNED, PRIMARY KEY (song_id))");

	$db->do("CREATE TABLE votes (song_id INT UNSIGNED, who VARCHAR(256),
		player_id VARCHAR(256), time INT UNSIGNED, priority INT,
		UNIQUE(song_id, who))");

	$db->do("CREATE TABLE history (song_id INT UNSIGNED, time TIMESTAMP, who
		VARCHAR(256), player_id VARCHAR(256))");

	$db->do("CREATE TABLE players (player_id VARCHAR(256), volume INT UNSIGNED,
		song_id INT UNSIGNED, song_start INT UNSIGNED, local_id VARCHAR(256),
		remote_id VARCHAR(256), queue_hint TEXT, PRIMARY KEY(player_id))");

	$db->do("CREATE TABLE playlists (who VARCHAR(256) NOT NULL, playlist_id INT
		AUTO_INCREMENT PRIMARY KEY, title VARCHAR(256) NOT NULL)");

	$db->do("CREATE TABLE playlist_contents (playlist_id INT UNSIGNED, song_id
		INT UNSIGNED, priority INT, UNIQUE(playlist_id,song_id))");
}

# MySQL fails hard on selecting a random song. see:
# http://www.paperplanes.de/2008/4/24/mysql_nonos_order_by_rand.html
sub get_random_song {
	my $self  = shift;
	my $count = shift;
	my $seed = shift;
	return $self->query(
		'get_random_songs', {-limit => $count}, {random => $self->rand($seed)},
	);
}

sub get_voters_by_time {
	my $self = shift;
	return @{$self->db->selectcol_arrayref(
		'SELECT who FROM votes WHERE player_id = ?
		GROUP BY who ORDER BY MIN(time)',
		undef, $self->player_id,
	)};
}

sub get_songs_by_votes {
	my $self = shift;

	# Make a hash mapping voters to all the songs they have voted for
	my $select_votes = $self->db->prepare('
		SELECT votes.song_id, votes.time, votes.who, votes.priority,
		songs.artist, songs.album, songs.title, songs.length, songs.path,
		songs.track FROM votes INNER JOIN songs ON votes.song_id =
		songs.song_id WHERE votes.player_id = ?
	');
	$select_votes->execute($self->player_id);

	my %votes;
	while (my $row = $select_votes->fetchrow_hashref()) {
		my $who = delete $row->{who}; # remove the who, save it
		$row->{time} = str2time($row->{time});
		my $priority = delete $row->{priority};
		$votes{$row->{song_id}} ||= $row;
		$votes{$row->{song_id}}{priority}{$who} = $priority;
		push @{$votes{$row->{song_id}}{who}}, $who;
	}

	return %votes;
}

sub get_playlist {
	my $self = shift;
	my @playlist = $self->queue->list;

	my $player = $self->query('select_players', {player_id => $self->player_id});
	$player->{song_id} ||= 0;
	return grep {$player->{song_id} != $_->{song_id}} @playlist;
}

sub get_current_song {
	my $self = shift;
	my @playlist = $self->queue->list;
	return $playlist[0] if @playlist;
	return;
}

sub get_history {
	my $self   = shift;
	my $amount = shift;
	my $voter  = shift;

	my %where = (player_id => $self->player_id);
	$where{who} = $voter if $voter;
	my @times = $self->query(
		'get_time_from_history', {%where, -limit => $amount},
	);
	if (@times) {
		return $self->query(
			'get_history', \%where, {},
			{%where, time => $times[-1]{time}, player_id => $self->player_id},
		);
	}

	return;
}

sub vote {
	my $self = shift;
	my $song_id = shift;
	my $who = shift;

	my $sth = $self->db->prepare('SELECT max(priority) FROM votes WHERE who = ?
			AND player_id = ?');
	$sth->execute($who, $self->player_id);
	my($maxpri) = $sth->fetchrow_array() || 0;
	$sth = $self->db->prepare('SELECT count(*) FROM votes WHERE who = ?
			AND player_id = ?');
	$sth->execute($who, $self->player_id);
	my($num_votes) = $sth->fetchrow_array() || 0;
	# Cap # of votes per voter
	my $maxvotes = $self->config->{player}{max_votes} || 0;
	$maxvotes = 0 if $maxvotes < 0;
	if ($num_votes < $maxvotes || !$maxvotes){
		my $db = $self->config->{database}{data_source};
		if ($db =~ m{^dbi:mysql}i) {
			$sth = $self->db->prepare(
				'INSERT IGNORE INTO votes (song_id, time, player_id, who, priority)
				VALUES (?, now(), ?, ?, ?)'
			);
		} else {
			$sth = $self->db->prepare(
				'INSERT INTO votes (song_id, time, player_id, who, priority)
				VALUES (?, date(\'now\'), ?, ?, ?)'
			);
		}
		# Try to process the vote. Failures are usually due to duplicates.
		# and really should just be ignored.
		try {
			$sth->execute($song_id, $self->player_id, $who, $maxpri + 1);
		}
	}
}

sub player {
	my $self = shift;
	my $act  = shift;

	my $player_class = $self->config->{player}{module};
	load $player_class;

	$player_class->$act($self, @_);
}

sub rpc {
	my $self = shift;
	my $act  = shift;

	my $rpc_class = $self->config->{player}{rpc};
	load $rpc_class;

	$rpc_class->$act($self, @_);
}

=head2 test

Provides lazy access to testing routines in Acoustics::Test. See
L<Acoustics::Test>. (Basically turns C<<$ac->test->hats(@clowns)>> into
C<<Acoustics::Test::hats($ac, @clowns)>>.)

=cut

sub test {
	my $self = shift;
	my $act  = shift;

	require Acoustics::Test;

	my $routine = Acoustics::Test->can($act);
	if ($routine) {
		$routine->($self, @_);
	} else {
		die "whoa! '$routine' is not a valid method in Acoustics::Test\n";
	}
}

sub reinit {
	my $self = shift;

	return Acoustics->new({
		config_file => $self->config_file,
		player_id   => $self->player_id,
	});
}

# Mysql has RAND, everyone else has RANDOM
# TODO: Make this a stored procedure
sub rand {
	my $self = shift;
	my $seed = shift;
	$seed = rand(1e9) if !$seed || $seed =~ /\D/;
	my $db = $self->config->{database}{data_source};
	if ($db =~ m{^dbi:mysql}i) {
		return "RAND($seed)";
	}
	elsif ($db =~ m{^dbi:(pg|sqlite)}i) {
		return "RANDOM()";
	}
	# A propable default. Hack if yours is different
	else {
		return "RANDOM()";
	}
}

sub dedupe
{
	my $self = shift;
	my @input = grep {$_->{title} ne ""} @_;

	my %songs = map {
		join(' ', uc(join '', ($_->{title} =~ /\S+/g)),
		uc(join '', ($_->{artist} =~ /\S+/g)),
		uc(join '', ($_->{album} =~ /\S+/g)))
		=> $_
	} @input;


	return sort {$a->{album} cmp $b->{album}} (sort {$a->{track} <=> $b->{track}} (values %songs));
}

=head1 EXTENSION SYSTEM

Acoustics provides a system for writing extensions that affect existing
behavior and add new behavior.

=head2 ext_hook(COMPONENT, 'event', \%parameters)

This method is called when a part of Acoustics wants to provide a hook for an
extension here. It represents when an event is called.

COMPONENT should be a string that defines your component, such as 'player' or
'web'. It is recommended that a constant is used for this within your file,
since it should be consistent.

'event' is a string that defines the event name. This should be unique within
COMPONENT. Examples of this parameter are 'start' and 'stop' within the player
component.

COMPONENT and 'event' are joined by an underscore and then used as a function
name within each plugin. Thus, this must form a valid function name.

This function is called with $acoustics as the first argument, followed by the
parameters hashref. The parameter hashref's contents vary depending on the
method calling.

The list of items returned by the extensions are returned in list context. See
C<ext_return> below.

=cut

{
my @ext_returns;

sub ext_hook {
	my $self      = shift;
	my $component = shift;
	my $event     = shift;
	my $params    = shift;
	$params     ||= {};

	my $routine = join '_', $component, $event;

	my @extensions = split /\s*,\s*/, $self->config->{_}{extensions};

	# Yes, in fact, you can do this. It is only meaningful due to our use of
	# try/catch below and prevents the player from exiting instantly.
	local $SIG{__DIE__} = 'IGNORE';
	for my $ext (@extensions) {
		my $class = "Acoustics::Extension::$ext";
		last if try {
			load $class;
			my $code = $class->can($routine);
			my $rv   = $code ? $code->($self, dclone($params)) : undef;

			# test for our magic value
			return ref($rv) =~ /Acoustics::INTERNAL::ext_stop/;
		} catch {
			use Carp 'longmess';
			$logger->error(longmess($_));
		};
	}

	my @return = @ext_returns;
	@ext_returns = ();
	return @return;
}

sub ext_return {
	my $self  = shift;
	my $value = shift;

	push @ext_returns, $value;
}

sub ext_stop {
	my $self = shift;

	# TODO: do this better...
	bless [], 'Acoustics::INTERNAL::ext_stop';
}

}

1;
