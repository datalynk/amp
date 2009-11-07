package Acoustics;

use strict;
use warnings;

use Mouse;
use DBI;

has 'db' => (is => 'ro', isa => 'DBI', handles => [qw(begin_work commit)]);
has 'data_source' => (is => 'ro', isa => 'Str');

has 'voter_order' => (is => 'rw', isa => 'ArrayRef[Str]', default => sub {[]});

sub BUILD {
	my $self = shift;

	$self->{db} = DBI->connect(
		'dbi:SQLite:' . $self->data_source,
		'', '', # user, pass
		{RaiseError => 1, AutoCommit => 1},
	);
}

sub check_if_song_exists {
	my $self = shift;
	my $path = shift;

	my @rows = $self->db->selectrow_array(
		'SELECT count(*) FROM songs WHERE path = ?',
		undef, $path,
	);

	return $rows[0];
}

sub add_song {
	my $self = shift;
	my $data = shift;

	my $sth = $self->db->prepare('
		INSERT INTO songs(artist, album, title, length, track, path)
		VALUES(?, ?, ?, ?, ?, ?)
	');

	$sth->execute((map {$data->{$_}} qw(artist album title length track path)));
}

sub update_song {
	my $self = shift;
	my $data = shift;

	my $sth = $self->db->prepare('
		UPDATE songs SET artist=?, album=?, title=?, length=?, track=?
		WHERE path = ?
	');

	$sth->execute((map {$data->{$_}} qw(artist album title length track path)));
}

sub get_playlist {
	my $self = shift;

	# Find all the voters, and add them to our ordering
	my @voter_list = @{$self->db->selectcol_arrayref(
		'SELECT who FROM votes GROUP BY who ORDER BY MIN(time)'
	)};

	# add any voters that we don't have listed to the end of the queue
	for my $who (@voter_list) {
		push @{$self->voter_order}, $who unless $who ~~ $self->voter_order;
	}

	# Make a hash mapping voters to all the songs they have voted for
	my %votes;
	my $select_votes = $self->db->prepare('
		SELECT votes.song_id, votes.who, songs.artist, songs.album,
		songs.title, songs.length, songs.path FROM votes INNER JOIN songs ON
		votes.song_id == songs.song_id
	');
	$select_votes->execute();
	while (my $row = $select_votes->fetchrow_hashref()) {
		my $who = delete $row->{who}; # remove the who, save it
		$votes{$row->{song_id}} ||= $row;
		push @{$votes{$row->{song_id}}{who}}, $who; # re-add the voter
	}

	# round-robin between voters, removing them from the temporary voter list
	# when all their songs are added to the playlist
	my @songs;
	while (@voter_list) {
		# pick the first voter
		my $voter = shift @voter_list;

		# find all songs matching this voter and sort by number of voters
		my @candidates = grep {$_->{who} ~~ $voter} values %votes;
		@candidates    = sort {$a->{who} <=> $b->{who}} @candidates;

		# if this user has no more stored votes, ignore them
		next unless @candidates;

		# grab the first candidate, remove it from the hash of votes
		push @songs, delete $votes{$candidates[0]{song_id}};

		# re-add the voter to the list since they probably have more songs
		push @voter_list, $voter;
	}

	unless (@songs) {
		# if we don't have any votes, then get a random song
		@songs = $self->db->selectrow_hashref(
			'SELECT song_id, title, artist, album, path, length
			FROM songs ORDER BY RANDOM() LIMIT 1'
		);
	}

	return @songs;
}

sub delete_vote {
	my $self = shift;
	my $song = shift;

	my $sth = $self->db->prepare('DELETE FROM votes WHERE song_id = ?');
	$sth->execute($song);
}

sub add_playhistory {
	my $self = shift;
	my $data = shift;

	my $sth = $self->db->prepare(
		'INSERT INTO history(song_id, who, time, pretty_name) values(?, ?, ?, ?)'
	);
	$sth->execute(
		$data->{song_id}, '', time, "$data->{artist} - $data->{title}",
	);
}

sub delete_song {
	my $self = shift;
	my $song = shift;

	my $sth = $self->db->prepare('DELETE FROM songs WHERE song_id = ?');
	$sth->execute($song);
}

sub get_library {
	my $self = shift;

	my $sth = $self->db->prepare("SELECT * FROM songs ORDER BY artist,album,track ASC");

	$sth->execute();

	my @songs = @{$sth->fetchall_arrayref({})};
}

sub vote {
	my $self = shift;
	my $song_id = shift;

	my $sth = $self->db->prepare("INSERT INTO votes (song_id, time) VALUES (?,?)");

	$sth->execute($song_id, time);
}

1;
