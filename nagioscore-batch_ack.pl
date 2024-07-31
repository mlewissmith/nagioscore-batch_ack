#!/usr/bin/perl

=head1 NAME

nagioscore-batch_ack - Batch acknowledge service/host problems for NAGIOS CORE

=head1 SYNOPSIS

B<nagioscore-batch_ack> [I<OPTIONS>]

=head1 DESCRIPTION

Batch acknowledge service/host problems for NAGIOS CORE.

Tested with NAGIOS CORE 4.x.

=cut

use strict;
use warnings;
use feature qw(say);

use Getopt::Long;
use Pod::Usage;

use Term::ANSIColor qw(color colored colorstrip);
use Term::ReadLine;

use Data::Dumper;
$Data::Dumper::Sortkeys = 1;
$Data::Dumper::Terse = 1;
$Data::Dumper::Indent = 1;

use Storable;
use JSON;

$|++;

our $PKG_NAME = "nagioscore-batch_ack";
our $PKG_VERSION = "0.1.1";

our %opt = ( ##GENERAL
             'problem-hosts'        => 1,
             'problem-services'     => 1,
             'hosts'                => ".", # regex
             'hostgroups'           => ".", # regex
             'services'             => ".", # regex
             'servicegroups'        => ".", # regex
             'ignore-problem-hosts' => 1,   # bool
             'ignore-acknowledged'  => 1,   # bool
             'ignore-ok'            => 1,   # bool
             'acknowledge'          => 0,   # bool
             'message'              => "",  # text
             'message-author'       => getlogin || getpwuid($<) || $0,  # text
             'color',               => -t STDOUT,  # bool
             ##NAGIOS_FILES
             'status_file'          => "/var/spool/nagios/status.dat",     ## status_dat
             'objects_cache_file'   => "/var/spool/nagios/objects.cache",  ## objects_cache
             'command_file'         => "/var/spool/nagios/cmd/nagios.cmd", ## command_file
             ##DEBUG
             'debug'                => 0,   # bool
             'debug-dump'           => "",  # filename
             );

## hashref
our $nagdata;
our @hsinfo = ( { text => "[-UP-]", color => "cyan" },
                { text => "[DOWN]", color => "white on_red" } );
our @ssinfo = ( { text => "[-OK-]", color => "cyan" },
                { text => "[WARN]", color => "bright_yellow" },
                { text => "[CRIT]", color => "bright_red" },
                { text => "[UNKN]", color => "faint" },
                { text => "[DPND]", color => "faint" } );

################################################################################

sub ltrim { my $s = shift; $s =~ s/^\s+//;       return $s };
sub rtrim { my $s = shift; $s =~ s/\s+$//;       return $s };
sub  trim { my $s = shift; $s =~ s/^\s+|\s+$//g; return $s };

sub dprint {
    return unless $opt{debug};
    my ($_package, $_file, $_line) = caller;
    my @_c = caller(1);
    my $_subroutine = (defined $_c[3])?$_c[3]:$_package;
    @_ = ('#' x 8) unless @_;
    foreach my $arg (@_) {
        my @lines = split "\n", $arg;
        foreach my $l (@lines) {
            warn "${_file}($_line)(${_subroutine}) $l\n";
        }
    }
}

sub dump_to_file {
    ## usage:
    ##   dump_to_file( $DATAREF, $FILENAME );
    ## Saves FILENAME      (Storable)
    ##       FILENAME.txt  (Data::Dumper)
    ##       FILENAME.json (JSON)
    my $datahash = shift;
    my $pstor = shift;
    my $pstor_txt = "${pstor}.txt";
    my $pstor_json = "${pstor}.json";
    # FILENAME (Storable)
    dprint ">$pstor";
    store($datahash, $pstor) or die "$pstor: $!";
    ## FILENAME.txt (Data::Dumper)
    dprint ">$pstor_txt";
    open(PSTOR_TXT, ">$pstor_txt") or die "$pstor_txt: $!";
    print PSTOR_TXT Dumper $datahash;
    close PSTOR_TXT or die "$pstor_txt: $!";
    ## FILENAME.json (JSON)
    dprint ">$pstor_json";
    open(PSTOR_JSON, ">$pstor_json") or die("$pstor_json: $!");
    print PSTOR_JSON to_json($datahash, {utf8=>1,canonical=>1});
    close PSTOR_JSON or die "$pstor_json: $!";
}

sub objects2hash {
    ## usage:
    ##   my $hashref = status2hash('/var/spool/nagios/objects.cache')
    my $objects_cache = shift;
    dprint "<${objects_cache}";

    ## open-and-read objects_cache
    open(OBJECTS_CACHE, "<${objects_cache}") or die("${objects_cache}: $!");
    my @objects_cache = <OBJECTS_CACHE>;
    close OBJECTS_CACHE or die "${objects_cache}: $!";
    chomp @objects_cache;

    my $reading_a_record = 0;
    my $recordtype = "";
    my %record = ();
    my %objects = ();

    for my $line (@objects_cache) {
        ## beginning_of_record
        if ($line =~ m/^\s*define\s+(\w+)\s*\{$/) {
            $recordtype = "$1";
            $reading_a_record++;
            next;
        }
        ## record contents
        if ($reading_a_record && $line =~ m/^\s*(\w+)\s+(.*?)\s*$/) {
            $record{$1} = $2;
            next;
        }
        ## end_of_record
        if ($reading_a_record && $line =~ m/^\s*\}\s*$/) {
            push( @{$objects{$recordtype}}, {%record} );
            $recordtype = "";
            $reading_a_record = 0;
            %record = ();
            next;
        }
    }

    return \%objects;
}

sub status2hash {
    ## usage:
    ##   my $hashref = status2hash('/var/spool/nagios/status.dat')
    my $status_dat = shift;
    dprint "<${status_dat}";

    ## open-and-read status.dat
    open(STATUS_DAT, "<${status_dat}") or die("${status_dat}: $!");
    my @status_dat = <STATUS_DAT>;
    close STATUS_DAT or die "${status_dat}: $!";
    chomp @status_dat;

    my $reading_a_record = 0;
    my $recordtype = "";
    my %record = ();
    my %statuses = ();

    for my $line (@status_dat) {
        ## beginning_of_record
        if ($line =~ m/^\s*(\w+)\s*\{$/) {
            $recordtype = "$1";
            $reading_a_record++;
            %record = ();
            next;
        }
        ## record contents
        if ($reading_a_record && $line =~ m/^\s*(\w+)=(.*?)\s*$/) {
            $record{$1} = $2;
            next;
        }
        ## end_of_record
        if ($reading_a_record && $line =~ m/^\s*\}\s*$/) {
            push( @{$statuses{$recordtype}}, {%record} );
            $recordtype = "";
            $reading_a_record = 0;
            %record = ();
            next;
        }
    }

    return \%statuses;
}

sub acknowledge_host_problem {
    ## usage:
    ##   acknowledge_host_problem($opt{command_file}, {HOSTSTATUS}, {MESSAGE});
    my $command_file = shift;
    my $status = shift;
    my $msgdata = shift;

    dprint $command_file;
    dprint $status;
    dprint $msgdata;

    my $epoch = time;
    my %ack = ( COMMAND => "ACKNOWLEDGE_HOST_PROBLEM",
                host => $status->{host_name},
                sticky => 2,
                notify => 1,
                persistent => 1,
                author => $msgdata->{author},
                comment => $msgdata->{message} );

    my $ackstr = join(';',
                      $ack{COMMAND},
                      $ack{host},
                      $ack{sticky},
                      $ack{notify},
                      $ack{persistent},
                      $ack{author},
                      $ack{comment});

    open(COMMAND_FILE, ">>${command_file}") or die ("${command_file}: $!");
    say COMMAND_FILE "[${epoch}] $ackstr";
    close COMMAND_FILE or die ("${command_file}: $!");
}

sub acknowledge_service_problem {
    ## usage:
    ##   acknowledge_service_problem($opt{command_file}, {SERVICESTATUS}, {MESSAGE});
    my $command_file = shift;
    my $status = shift;
    my $msgdata = shift;

    dprint $command_file;
    dprint $status;
    dprint $msgdata;

    my $epoch = time;
    my %ack = ( COMMAND => "ACKNOWLEDGE_SVC_PROBLEM",
                host => $status->{host_name},
                service => $status->{service_description},
                sticky => 2,
                notify => 1,
                persistent => 1,
                author => $msgdata->{author},
                comment => $msgdata->{message} );

    my $ackstr = join(';',
                      $ack{COMMAND},
                      $ack{host},
                      $ack{service},
                      $ack{sticky},
                      $ack{notify},
                      $ack{persistent},
                      $ack{author},
                      $ack{comment});

    open(COMMAND_FILE, ">>${command_file}") or die ("${command_file}: $!");
    say COMMAND_FILE "[${epoch}] $ackstr";
    close COMMAND_FILE or die ("${command_file}: $!");
}

sub read_prompt {
    ## usage:
    ##   my $reply = read_prompt($prompt_text, $default_reply);
    my $prompt_text = shift;
    my $default_reply = shift;

    $prompt_text = trim $prompt_text;
    $prompt_text = "$prompt_text [$default_reply]" if ($default_reply);
    $prompt_text .= '? ';

    my $trl = Term::ReadLine->new('read_prompt');
    ## turn off autohistory
    $trl->MinLine(undef);
    ## turn off pretty-print
    $trl->ornaments(0);

    my $reply = undef;
    while ( $reply = trim $trl->readline($prompt_text) ) {
        if ( $reply =~ m/^:(exit|quit|x|q)$/ ) {
            die "$reply";
        }
        if ( $reply =~ m/^:(help|\?)$/ ) {
            say "HELP...";
            next;
        }
        if ( $reply =~ m/:debug/ ) {
            dprint $trl->ReadLine;
            dprint Dumper $trl->Features();
            dprint Dumper $trl->Attribs();
            next;
        }
        if ( $reply =~ m/^:hist/ and $trl->Features()->{getHistory} ) {
            say $_ for $trl->GetHistory;
            next;
        }
        $trl->addhistory($reply) unless ($reply =~ m/[[:punct:]]/);
        return $reply;
    }
    return $default_reply;
}

sub display_hoststatus {
    ## usage:
    ##   display_hoststatus($hoststatus);
    my $hs = shift;
    my $hsi = $hsinfo[$hs->{current_state}];

    my %fields = ( state    => colored( $hsi->{text},
                                        $hsi->{color} ),
                   hostname => colored( $hs->{host_name},
                                        $hsi->{color} ),
                   command  => colored( $hs->{check_command},
                                        $hsi->{color} ),
                   output   => $hs->{plugin_output} );

    my $dispstr = "$fields{state} | $fields{hostname} | $fields{command} | $fields{output}";
    say $dispstr;
}

sub display_servicestatus {
    ## usage:
    ##   display_servicestatus($hoststatus,$servicestatus);
    my $hs = shift;
    my $ss = shift;
    my $hsi = $hsinfo[$hs->{current_state}];
    my $ssi = $ssinfo[$ss->{current_state}];

    my %fields = ( state    => colored( $ssi->{text},
                                        $ssi->{color} ),
                   hostname => colored( $hs->{host_name},
                                        $hsi->{color} ),
                   command  => colored( $ss->{service_description},
                                        $ssi->{color} ),
                   output   => $ss->{plugin_output} );

    my $dispstr = "$fields{state} | $fields{hostname} | $fields{command} | $fields{output}";
    say $dispstr;
}

################################################################################

=head1 OPTIONS

=over

=item B<--problem-hosts>|B<--no-problem-hosts>

=item B<--ph>|B<--no-ph>

Select problem hosts.  Default B<on>.


=item B<--problem-services>|B<--no-problem-services>

=item B<--ps>|B<--no-ps>

Select problem services.  Default B<on>.


=item B<--problems>|B<--no-problems>

=item B<--pp>|B<--no-pp>

Shortcut for B<--[no-]problem-hosts --[no-]problem-services>


=item B<--hosts> I<REGEXP>

=item B<--hh> I<REGEXP>

Select only hosts matching I<REGEXP>.


=item B<--hostgroups> I<REGEXP>

=item B<--hg> I<REGEXP>

Select only hosts which are members of hostgroup I<NAME>.


=item B<--services> I<REGEXP>

=item B<--ss> I<REGEXP>

Select only services matching I<REGEXP>.


=item B<--servicegroups> I<REGEXP>

=item B<--sg> I<REGEXP>

Select only services which are members of servicegroup I<REGEXP>.


=item B<--ignore-problem-hosts>|B<--no-ignore-problem-hosts>

=item B<--iph>|B<--no-iph>

Ignore service problems on problem hosts.  Default B<on>.


=item B<--ignore-acknowledged>|B<--no-ignore-acknowledged>

=item B<--ia>|B<--no-ia>

Ignore host or service problems which have already been acknowledged. Default B<on>.


=item B<--ignore-ok>|B<--no-ignore-ok> 

=item B<--iok>|B<--no-iok>

Ignore hosts or services which have no problems.


=item B<--acknowledge>|B<--no-acknowledge>

=item B<-a>|B<--no-a>

Acknowledge selected problems.  Default B<off>.



=item B<--message> I<TEXT>

=item B<-m> I<TEXT>

Acknowledgement message.  Requires B<--acknowledge>.  Default I<prompt>.


=item B<--message-author> I<USERNAME>

=item B<-U> I<USERNAME>

Specify the author of the acknowledgement message.  Requires B<--acknowledge>.  Default I<current user>.


=item B<--colour>|B<--no-colour>|B<--color>|B<--no-color>

Default B<on>.


=back

=head2 Nagios Files

=over

=item B<--status_file> I<FILE>

Default C</var/spool/nagios/status.dat>.


=item B<--objects_cache_file> I<FILE>

Default C</var/spool/nagios/objects.cache>.


=item B<--command_file> I<FILE>

Default C</var/spool/nagios/cmd/nagios.cmd>.


=back

=head2 Help

=over

=item B<--help>|B<-h>

=item B<--options>|B<-H>

=item B<--version>|B<-V>

=item B<--man>

Help in varying degrees of verbosity.

=back

=cut

Getopt::Long::Configure(qw(gnu_getopt no_ignore_case));
GetOptions(\%opt,
           ### DEBUG
           'debug|D!',
           'debug-fetch|DF=s' => sub {
               system("scp $_[1]:$opt{status_file} .");
               system("scp $_[1]:$opt{objects_cache_file} .");
               exit;
           },
           'debug-dump|DD=s',
           ## GENERAL
           'problem-hosts|ph!',
           'problem-services|ps!',
           'problems|pp!' => sub { $opt{'problem-hosts'} = $opt{'problem-services'} = $_[1] },
           'hosts|host|hh=s',
           'hostgroups|hostgroup|hg=s',
           'services|service|ss=s',
           'servicegroups|servicegroup|sg=s',
           'ignore-problem-hosts|iph!',
           'ignore-acknowledged|ia!',
           'ignore-ok|iok!',
           'acknowledge|a!',
           'message|m=s',
           'message-author|U=s',
           'color|colour!',
           ### NAGIOS FILES
           'status_file=s',
           'objects_cache_file=s',
           'command_file=s',
           ### HELP
           'version|V'      => sub { pod2usage(-verbose => 0, -message => "${PKG_NAME} ${PKG_VERSION}") },
           'help|h'         => sub { pod2usage(-verbose => 0, -message => "${PKG_NAME} ${PKG_VERSION}") },
           'options|opts|H' => sub { pod2usage(-verbose => 1, -message => "${PKG_NAME} ${PKG_VERSION}") },
           'man|M'          => sub { pod2usage(-verbose => 2, -message => "${PKG_NAME} ${PKG_VERSION}") },
    ) or pod2usage(-verbose => 0);
dprint Dumper \%opt, \@ARGV;

$ENV{ANSI_COLORS_DISABLED} = $opt{color}?0:1;

$nagdata = { 'OBJECTS_CACHE_FILE' => objects2hash($opt{'objects_cache_file'}),
             'STATUS_FILE'        => status2hash($opt{'status_file'}) };

## hoststatus
dprint "collating hoststatus";
for my $h ( @{$nagdata->{'STATUS_FILE'}{hoststatus}} ) {
    my $host_name = $h->{host_name};
    $nagdata->{hoststatus}{$host_name} = $h;
}

## servicestatus
dprint "collating servicestatus";
for my $s ( @{$nagdata->{'STATUS_FILE'}{servicestatus}} ) {
    my $host_name = $s->{host_name};
    my $service_description = $s->{service_description};
    $nagdata->{servicestatus}{$host_name}{$service_description} = $s;
}

## hostgroups
dprint "collating hostgroups";
for my $h ( @{$nagdata->{'OBJECTS_CACHE_FILE'}{hostgroup}} ) {
    my $hostgroup_name = $h->{hostgroup_name};
    next unless ( $h->{members} );
    my @members = split(',', $h->{members});
    while ( @members ) {
        my $host = shift @members;
        $nagdata->{hostgroups}{byhost}{$host}{$hostgroup_name}++;
        $nagdata->{hostgroups}{bygroup}{$hostgroup_name}{$host}++;
    }
}

## servicegroup
dprint "collating servicegroups";
for my $s ( @{$nagdata->{'OBJECTS_CACHE_FILE'}{servicegroup}} ) {
    my $servicegroup_name = $s->{servicegroup_name};
    next unless ( $s->{members} );
    my @members = split(',', $s->{members});
    while ( @members ) {
        my $host = shift @members;
        my $service = shift @members;
        $nagdata->{servicegroups}{byhost}{$host}{$servicegroup_name}{$service}++;
        $nagdata->{servicegroups}{bygroup}{$servicegroup_name}{$host}{$service}++;
    }
}

dump_to_file($nagdata, $opt{'debug-dump'}) if $opt{'debug-dump'};

### AWESOME! we have read the configs.

my %ackdata = ( message => $opt{'message'},
                author => $opt{'message-author'} );

if ($opt{'problem-hosts'}) {
    for my $hostname ( sort keys %{$nagdata->{hoststatus}} ) {
        my $hoststatus = $nagdata->{hoststatus}{$hostname};
        my $hostgroups = $nagdata->{hostgroups}{byhost}{$hostname};

        next if ( $hoststatus->{current_state} == 0 and $opt{'ignore-ok'} );
        next if ( $hoststatus->{problem_has_been_acknowledged} and $opt{'ignore-acknowledged'} );
        next unless ( $hostname =~ m/$opt{hosts}/ );
        next unless ( grep { m/$opt{hostgroups}/ } keys %$hostgroups );

        display_hoststatus($hoststatus);
        if ( $opt{acknowledge}
             and $hoststatus->{current_state}
             and not $hoststatus->{problem_has_been_acknowledged} ) {
            unless ($opt{message}) {
                my $reply = read_prompt("$ackdata{author}:COMMENT", $ackdata{message});
                next unless $reply;
                next if ($reply =~ /^[[:punct:]]/);
                $ackdata{message} = $reply;
            }
            acknowledge_host_problem($opt{'command_file'}, $hoststatus, \%ackdata) or die "[DEBUG] die";
        }
    }
}

if ($opt{'problem-services'}) {
    for my $hostname ( sort keys %{$nagdata->{servicestatus}} ) {
        my $hoststatus = $nagdata->{hoststatus}{$hostname};
        my $hostgroups = $nagdata->{hostgroups}{byhost}{$hostname};
        my $servicegroups = $nagdata->{servicegroups}{byhost}{$hostname};

        next if ($hoststatus->{current_state} and $opt{'ignore-problem-hosts'});
        next unless ( $hostname =~ m/$opt{hosts}/ );
        next unless ( grep { m/$opt{hostgroups}/ } keys %$hostgroups );

        my @sg_members = grep { m/$opt{servicegroups}/ } keys %$servicegroups;

        for my $servicename ( sort keys %{$nagdata->{servicestatus}{$hostname}} ) {
            my $servicestatus = $nagdata->{servicestatus}{$hostname}{$servicename};

            next if ( $servicestatus->{current_state} == 0 and $opt{'ignore-ok'} );
            next if ( $servicestatus->{problem_has_been_acknowledged} and $opt{'ignore-acknowledged'} );
            next unless ( $servicename =~ m/$opt{services}/ );
            next unless ( grep { $_ eq $servicename } map { keys %{$servicegroups->{$_}} } @sg_members );

            display_servicestatus($hoststatus, $servicestatus);
            if ( $opt{acknowledge}
                 and $servicestatus->{current_state}
                 and not $servicestatus->{problem_has_been_acknowledged} ) {
                unless ($opt{message}) {
                    my $reply = read_prompt("$ackdata{author}:COMMENT", $ackdata{message});
                    next unless $reply;
                    next if ($reply =~ /^[[:punct:]]/);
                    $ackdata{message} = $reply;
                }
                acknowledge_service_problem($opt{'command_file'}, $servicestatus, \%ackdata) or die "[DEBUG] die";
            }
        }
    }
}
