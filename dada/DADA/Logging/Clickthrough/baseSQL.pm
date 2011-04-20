package DADA::Logging::Clickthrough::baseSQL;

use lib qw(../../../ ../../../DADA/perllib);

use strict;

use Fcntl qw(
  O_WRONLY
  O_TRUNC
  O_CREAT
  O_RDWR
  O_RDONLY
  LOCK_EX
  LOCK_SH
  LOCK_NB);
use Carp qw(croak carp);

use DADA::Config qw(!:DEFAULT);
use DADA::App::Guts;    # For now, my dear.

my $t = $DADA::Config::DEBUG_TRACE->{DADA_Logging_Clickthrough};

sub new {

    my $class  = shift;
    my ($args) = @_;
    my $self   = {};
    bless $self, $class;
    $self->_init($args);
    $self->_sql_init($args);
    return $self;
}

sub _sql_init {

    my $self = shift;
    require DADA::App::DBIHandle;
    my $dbi_obj = DADA::App::DBIHandle->new;
    $self->{dbh} = $dbi_obj->dbh_obj;
}

sub custom_fields {
    my $self = shift;
    my $cols = $self->_columns;

    my %omit_fields = (
        url_id      => 1,
        redirect_id => 1,
        msg_id      => 1,
        url         => 1,
    );

    my $custom = [];
    for (@$cols) {
        if ( !exists( $omit_fields{$_} ) ) {
            push( @$custom, $_ );
        }
    }
    return $custom;
}

sub _columns {

    my $self = shift;
    my @cols;

    if ( exists( $self->{cache}->{columns} ) ) {
        return $self->{cache}->{columns};
    }
    else {
        my $query =
            "SELECT * FROM "
          . $DADA::Config::SQL_PARAMS{clickthrough_urls_table}
          . " WHERE (1 = 0)";
        warn 'Query: ' . $query
          if $t;

        my $sth = $self->{dbh}->prepare($query);

        $sth->execute()
          or croak "cannot do statement (at: columns)! $DBI::errstr\n";
        my $i;
        for ( $i = 1 ; $i <= $sth->{NUM_OF_FIELDS} ; $i++ ) {
            push( @cols, $sth->{NAME}->[ $i - 1 ] );
        }
        $sth->finish;
        $self->{cache}->{columns} = \@cols;
    }
    return \@cols;
}

sub add {

    my $self = shift;
    my $mid  = shift;
    die 'no mid! ' if !defined $mid;
    my $url    = shift;
    my $fields = shift;

    my $key = $self->random_key();

    my $sql_str             = '';
    my $place_holder_string = '';
    my @order               = @{ $self->custom_fields };
    my @values;
    if ( $order[0] ) {
        for my $field (@order) {
            $sql_str .= ',' . $field;
            $place_holder_string .= ',?';
            push( @values, $fields->{$field} );
        }
    }
    $sql_str =~ s/,$//;

    my $query =
        'INSERT INTO '
      . $DADA::Config::SQL_PARAMS{clickthrough_urls_table}
      . '(redirect_id, msg_id, url'
      . $sql_str
      . ') values(?,?,?'
      . $place_holder_string . ')';

    warn 'Query: ' . $query
      if $t;

    my $sth = $self->{dbh}->prepare($query);
    $sth->execute( $key, $mid, $url, @values )
      or croak "cannot do statement! (at: add) $DBI::errstr\n";
    return $key;

}

sub reuse_key {

    my $self = shift;
    my $mid  = shift;
    die 'no mid! ' if !defined $mid;
    my $url    = shift;
    my $fields = shift;

    my $custom_fields = $self->custom_fields;
    my %cust_fields   = ();
    foreach (@$custom_fields) {
        $cust_fields{$_} = 1;
    }
    my $place_holder_string = '';
    my @values              = ();

    foreach my $field ( keys %$fields ) {
        if ( exists( $cust_fields{$field} ) ) {
            push( @values, $fields->{$field} );
            $place_holder_string .= ' AND ' . $field . ' = ?';
        }
    }
    my $query =
        'SELECT * FROM '
      . $DADA::Config::SQL_PARAMS{clickthrough_urls_table}
      . ' WHERE msg_id = ? AND url = ? '
      . $place_holder_string;

    warn 'QUERY: ' . $query
 		if $t;
    my $sth = $self->{dbh}->prepare($query);
    $sth->execute( $mid, $url, @values )
      or croak "cannot do statement! (at: reuse_key) $DBI::errstr\n";
    my $hashref;
  FETCH: while ( $hashref = $sth->fetchrow_hashref ) {
        $sth->finish;
        return $hashref->{redirect_id};
    }

    return undef;

}

sub fetch {

    my $self = shift;
    my $key  = shift;
    die "no key! " if !defined $key;

    my $sql_snippet = '';
    my $fields      = $self->custom_fields;
    foreach (@$fields) {
        $sql_snippet .= ', ' . $_;
    }

    my $query =
        'SELECT msg_id, url'
      . $sql_snippet
      . ' FROM '
      . $DADA::Config::SQL_PARAMS{clickthrough_urls_table}
      . ' WHERE  redirect_id = ?';
    warn 'QUERY: ' . $query
      if $t;

    my $sth = $self->{dbh}->prepare($query);
    $sth->execute($key)
      or croak "cannot do statement! (at: fetch) $DBI::errstr\n";
    my $hashref;
  FETCH: while ( $hashref = $sth->fetchrow_hashref ) {
        $sth->finish;
        my $msg_id = $hashref->{msg_id};
        my $url    = $hashref->{url};
        delete( $hashref->{msg_id} );
        delete( $hashref->{url} );
        return ( $msg_id, $url, $hashref );
    }

    return ( undef, undef, {} );
}

sub key_exists {

    my $self = shift;
    my ($args) = @_;

    my $query =
        'SELECT COUNT(*) FROM '
      . $DADA::Config::SQL_PARAMS{clickthrough_urls_table}
      . ' WHERE redirect_id = ? ';

    warn 'QUERY: ' . $query
      if $t;

    my $sth = $self->{dbh}->prepare($query);

    $sth->execute( $args->{-key} )
      or croak "cannot do statement (at key_exists)! $DBI::errstr\n";
    my @row = $sth->fetchrow_array();
    $sth->finish;
    return $row[0];

}

sub r_log {

    my $self      = shift; 
    my ($args)    = @_;
	my $timestamp = undef; 
	if(exists($args->{-timestamp})){ 
		$timestamp = $args->{-timestamp};
	}
	my $atts = {};
	if(exists($args->{-atts})){ 
		$atts = $args->{-atts};
	}
	
    if ( $self->{is_redirect_on} == 1 ) {
        my $place_holder_string = '';
        my $sql_snippet         = '';

        my @values    = ();
        my $fields    = $self->custom_fields;
        my $lt_fields = {};
        foreach (@$fields) {
            $lt_fields->{$_} = 1;
        }

        foreach ( keys %$atts ) {
            if ( exists( $lt_fields->{$_} ) ) {
                push( @values, $atts->{$_} );
                $place_holder_string .= ' ,?';
                $sql_snippet .= ' ,' . $_;
            }
        }
		my $ts_snippet = ''; 
		if(defined($timestamp)){ 
			$ts_snippet = 'timestamp,'; 
			$place_holder_string .= ' ,';
		}
        my $query =
            'INSERT INTO dada_clickthrough_url_log(list,' . $ts_snippet .'msg_id, url'
          . $sql_snippet
          . ') VALUES (?, ?, ?'
          . $place_holder_string . ')';

        my $sth = $self->{dbh}->prepare($query);
        if(defined($timestamp)){ 
			$sth->execute($self->{name}, $timestamp, $args->{-mid}, $args->{-url}, @values );
		}
		else { 
			$sth->execute($self->{name}, $args->{-mid}, $args->{-url}, @values );			
		}
        $sth->finish;

        return 1;
    }
    else {
        return 0;
    }
}

sub o_log {
    my ( $self, $mid ) = @_;
    if ( $self->{is_log_openings_on} == 1 ) {
        my $query =
'INSERT INTO dada_mass_mailing_event_log(list, msg_id, event) VALUES (?, ?, ?)';
        my $sth = $self->{dbh}->prepare($query);
        $sth->execute($self->{name}, $mid, 'open' );
        $sth->finish;
        return 1;
    }
    else {
        return 0;
    }
}

sub sc_log {
    my ( $self, $mid, $sc ) = @_;
    if ( $self->{enable_subscriber_count_logging} == 1 ) {
        my $query =
'INSERT INTO dada_mass_mailing_event_log(list, msg_id, event, details) VALUES (?, ?, ?, ?)';
        my $sth = $self->{dbh}->prepare($query);
        $sth->execute($self->{name}, $mid, 'num_subscribers', $sc );
        $sth->finish;

        return 1;
    }
    else {
        return 0;
    }
}

sub bounce_log {
    my ( $self, $type, $mid, $email ) = @_;
    if ( $self->{is_log_bounces_on} == 1 ) {

        my $bounce_type = '';
        if ( $type eq 'hard' ) {
            $bounce_type = 'hard_bounce';
        }
        else {
            $bounce_type = 'soft_bounce';
        }
        my $query =
'INSERT INTO dada_mass_mailing_event_log(list, msg_id, event, details) VALUES (?, ?, ?, ?)';
        my $sth = $self->{dbh}->prepare($query);
        $sth->execute($self->{name}, $mid, $bounce_type, $email );
        $sth->finish;

        close(LOG);
        return 1;
    }
    else {
        return 0;
    }
}

sub unique_and_dupe {
    my $self  = shift;
    my $array = shift;

    my @unique = ();
    my %seen   = ();

    foreach my $elem (@$array) {
        next if $seen{$elem}++;
        push @unique, $elem;
    }
    return [@unique];

}

sub report_by_message_index {
    my $self          = shift;
    my $sorted_report = [];
    my $report        = {};
    my $l;

  # postgres: $query .= ' SELECT DISTINCT ON(' . $subscriber_table . '.email) ';

# This query could probably be made into one, if I could simple use a join, or something,
    my $msg_id_query1 =
      'SELECT msg_id FROM dada_mass_mailing_event_log WHERE list = ? GROUP BY msg_id;';
    my $msg_id_query2 =
      'SELECT msg_id FROM dada_clickthrough_url_log WHERE list = ? GROUP BY msg_id;';

    my $msg_id1 = $self->{dbh}->selectcol_arrayref($msg_id_query1, {}, ($self->{name})); #($statement, \%attr, @bind_values);
    my $msg_id2 = $self->{dbh}->selectcol_arrayref($msg_id_query2, {}, ($self->{name}));
    push( @$msg_id1, @$msg_id2 );
    $msg_id1 = $self->unique_and_dupe($msg_id1);

    for my $msg_id (@$msg_id1) {

        $report->{$msg_id}->{msg_id} = $msg_id;

        # Clickthroughs
        my $clickthrough_count_query =
'SELECT COUNT(msg_id) FROM dada_clickthrough_url_log WHERE list = ?  AND msg_id = ?';
        $report->{$msg_id}->{count} =
          $self->{dbh}
          ->selectcol_arrayref( $clickthrough_count_query, {}, $self->{name}, $msg_id )->[0];

        my $misc_count_query =
'SELECT COUNT(msg_id) FROM dada_mass_mailing_event_log WHERE list = ? AND msg_id = ? AND event = ?';
        $report->{$msg_id}->{open} =
          $self->{dbh}
          ->selectcol_arrayref( $misc_count_query, {}, $self->{name}, $msg_id, 'open' )->[0];
        $report->{$msg_id}->{soft_bounce} =
          $self->{dbh}
          ->selectcol_arrayref( $misc_count_query, {}, $self->{name}, $msg_id, 'soft_bounce' )
          ->[0];
        $report->{$msg_id}->{hard_bounce} =
          $self->{dbh}
          ->selectcol_arrayref( $misc_count_query, {}, $self->{name}, $msg_id, 'hard_bounce' )
          ->[0];

        my $num_sub_query =
'SELECT details FROM dada_mass_mailing_event_log WHERE list = ? msg_id = ? AND event = ?';
        $report->{$msg_id}->{num_subscribers} =
          $self->{dbh}->selectcol_arrayref( $num_sub_query, { MaxRows => 1 },
            $self->{name}, $msg_id, 'num_subscribers' )->[0];

    }

    require DADA::MailingList::Archives;
    my $mja = DADA::MailingList::Archives->new( { -list => $self->{name} } );

    # Now, sorted:
    for ( sort { $b <=> $a } keys %$report ) {
        $report->{$_}->{mid} = $_;    # this again.
        $report->{$_}->{date} =
          DADA::App::Guts::date_this( -Packed_Date => $_, );

        if ( $mja->check_if_entry_exists($_) ) {
            $report->{$_}->{message_subject} = $mja->get_archive_subject($_)
              || $_;
        }
        else {
        }

        push( @$sorted_report, $report->{$_} );
    }

    #require Data::Dumper;
    #die Data::Dumper::Dumper($sorted_report);
    return $sorted_report;
}

sub report_by_message {

    my $self   = shift;
    my $msg_id = shift;

    my $report = {};
    my $l;

    my $num_sub_query =
'SELECT details FROM dada_mass_mailing_event_log WHERE list = ? AND msg_id = ? AND event = ?';
    $report->{num_subscribers} =
      $self->{dbh}->selectcol_arrayref( $num_sub_query, { MaxRows => 1 },
        $self->{name}, $msg_id, 'num_subscribers' )->[0];

    my $misc_count_query =
'SELECT COUNT(msg_id) FROM dada_mass_mailing_event_log WHERE list = ? AND msg_id = ? AND event = ?';

    #	# This may be different.
    $report->{open} =
      $self->{dbh}->selectcol_arrayref( $misc_count_query, {}, $self->{name}, $msg_id, 'open' )
      ->[0];
    $report->{soft_bounce} =
      $self->{dbh}
      ->selectcol_arrayref( $misc_count_query, {}, $self->{name}, $msg_id, 'soft_bounce' )
      ->[0];
    $report->{hard_bounce} =
      $self->{dbh}
      ->selectcol_arrayref( $misc_count_query, {}, $self->{name}, $msg_id, 'hard_bounce' )
      ->[0];

    my $url_clickthroughs_query =
'SELECT url, COUNT(url) AS count FROM dada_clickthrough_url_log where list = ? AND msg_id = ? GROUP BY url';
    my $sth = $self->{dbh}->prepare($url_clickthroughs_query);
    $sth->execute($self->{name}, $msg_id);
    my $url_report = [];
    my $row        = undef;
    while ( $row = $sth->fetchrow_hashref ) {
        push( @$url_report, { url => $row->{url}, count => $row->{count} } );
    }
    $sth->finish;
    undef $sth;
    $report->{url_report} = $url_report;

    for my $bounce_type (qw(soft_bounce hard_bounce)) {
        my $bounce_query =
'SELECT timestamp, details from dada_mass_mailing_event_log where list = ? AND msg_id = ? AND event = ? ORDER BY timestamp';
        my $sth = $self->{dbh}->prepare($bounce_query);
        $sth->execute($self->{name},  $msg_id, $bounce_type );
        my $bounce_report = [];
        while ( $row = $sth->fetchrow_hashref ) {
            push( @$bounce_report,
                { timestamp => $row->{timestamp}, email => $row->{details} } );
        }
        $report->{ $bounce_type . '_report' } = $bounce_report;
        $sth->finish;
    }

    #require Data::Dumper;
    #die Data::Dumper::Dumper($report);

    return $report;
}

sub export_logs {

    my $self = shift;
    my $type = shift;
    my $fh   = shift || \*STDOUT;

    my $l;

    require Text::CSV;
    my $csv = Text::CSV->new($DADA::Config::TEXT_CSV_PARAMS);

    my $query = '';
    if ( $type eq 'clickthrough' ) {
        $query = 'SELECT * FROM dada_clickthrough_url_log WHERE list = ?';
    }
    elsif ( $type eq 'activity' ) {
        $query = 'SELECT * FROM dada_mass_mailing_event_log WHERE list = ?';
    }

    my $sth = $self->{dbh}->prepare($query);
	   $sth->bind_columns($self->{name});
    $sth->execute();
    while ( my $fields = $sth->fetchrow_arrayref ) {
        my $status = $csv->print( $fh, $fields );
        print $fh "\n";
    }
}

1;
