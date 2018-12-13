package Data::Validate::Sanctions::Fetcher;

use strict;
use warnings;

use DateTime::Format::Strptime;
use IO::Uncompress::Unzip qw(unzip $UnzipError);
use List::Util qw/uniq/;
use Mojo::UserAgent;
use Text::CSV;
use Try::Tiny;
use XML::Fast;


our $VERSION = '0.10';

my $config = {
    'OFAC-SDN' => {
        description => 'TREASURY.GOV: Specially Designated Nationals List with a.k.a included',
        url    => 'https://www.treasury.gov/ofac/downloads/sdn_xml.zip',    #let's be polite and use zippped version of this 7mb+ file
        parser => \&_ofac_xml_zip,
    },
    'OFAC-Consolidated' => {
        description => 'TREASURY.GOV: Consolidated Sanctions List Data Files',
        url         => 'https://www.treasury.gov/ofac/downloads/consolidated/consolidated.xml',
        parser      => \&_ofac_xml,
    },
    'HMT-Sanctions' => {
        description => 'GOV.UK: Financial sanctions: consolidated list of targets',
        url         => 'http://hmt-sanctions.s3.amazonaws.com/sanctionsconlist.csv',
        parser      => \&_hmt_csv,
    },
};

#
# Parsers - returns timestamp of last update and arrayref of names
#

sub _process_name {
    my $r = join ' ', @_;
    $r =~ s/^\s+|\s+$//g;
    return $r;
}

sub _ofac_xml_zip {
    my $content = shift;
    my $output;
    unzip \$content => \$output or die "unzip failed: $UnzipError\n";
    return _ofac_xml($output);
}

sub _validate_date {

    my $file_date = shift;

    # Check if datetime is valid or not
    return 1 if $file_date =~ /^(\d{1,2})\/(\d{1,2})\/(\d{4})$/;

    return 0;
}

sub _ofac_xml {
    my $content = shift;

    my @names;
    my $ref = xml2hash($content, array => ['aka'])->{sdnList};
    my $ofac_ref = {};

    foreach my $entry (@{$ref->{sdnEntry}}) {
        next unless $entry->{sdnType} eq 'Individual';

        push @names, _process_name($_->{firstName} // '', $_->{lastName} // '') for ($entry, @{$entry->{akaList}{aka} // []});
        my $name = pop @names;

        $ofac_ref->{$name}->{dob_epoch} ||= [] ;

        my $dob = $entry->{dateOfBirthList}{dateOfBirthItem};

        # In one of the xml files, some of the clients have more than one date of birth
        # Hence, $dob can be either an array or a hashref
        my @dob_list = map { $_->{dateOfBirth} || () } (ref($dob) eq 'ARRAY' ? @$dob : $dob);

        foreach my $dob (@dob_list) {

            # Some of the values are only years (ex. '1946')
            # We don't want to include them
            next unless $dob !~ /^\d{4}$/;

            $dob =~ s/ /-/g;

            try {
                $dob = Date::Utility->new($dob);
                push @{$ofac_ref->{$name}->{dob_epoch}}, $dob->epoch;
            }
        }

    }

    die 'Datetime is invalid' unless (_validate_date($ref->{publshInformation}{Publish_Date}));

    my $parser = DateTime::Format::Strptime->new(
        pattern  => '%m/%d/%Y',
        on_error => 'croak',
    );

    return {
        updated    => $parser->parse_datetime($ref->{publshInformation}{Publish_Date})->epoch,    # 'publshInformation' is a real name
        names_list => $ofac_ref,
    };
}

sub _hmt_csv {
    my $content = shift;
    my $hmt_ref = {};

    my $csv = Text::CSV->new({binary => 1}) or die "Cannot use CSV: " . Text::CSV->error_diag();

    my @lines = split("\n",$content);
    my @info;
    my $i = 0;
    foreach (@lines){
        $i++;
        chop;
        my $status =  $csv->parse($_);
        if (1==$i){
            @info = $status ? $csv->fields() : () ;
            die 'Datetime is invalid' unless (@info && _validate_date($info[1]));
        }
        
        next unless $status;
        my @row = $csv->fields();
        my $row = \@row; 
        ($row->[23] and $row->[23] eq "Individual") or next;
        my $name = _process_name @{$row}[0 .. 5];

        next if $name =~ /^\s*$/;

        my $date_of_birth = $row->[7];
        $date_of_birth =~ tr/\//-/;

        $hmt_ref->{$name}->{dob_epoch} ||= [] ;

        # Some DOBs are invalid (Ex. 0-0-1968)
        try {
            my $dob_epoch = Date::Utility->new($date_of_birth)->epoch;
            push @{$hmt_ref->{$name}->{dob_epoch}}, $dob_epoch;

        }
    }

    my $parser = DateTime::Format::Strptime->new(
        pattern  => '%d/%m/%Y',
        on_error => 'croak',
    );

    return {
        updated    => $parser->parse_datetime($info[1])->epoch,
        names_list => $hmt_ref,
    };
}

=head2 run

Fetches latest version of lists, and returns combined hash of successfully downloaded ones

=cut

sub run {
    my $h  = {};
    my $ua = Mojo::UserAgent->new;
    $ua->connect_timeout(15);
    foreach my $id (keys %$config) {
        my $d = $config->{$id};
        try {

            die "File not downloaded for " . $d->{description} if $ua->get($d->{url})->result->is_error;

            my $r = $d->{parser}->($ua->get($d->{url})->result->body);

            if ($r->{updated} > 1) {
                $h->{$id} = $r;
            }
        }
        catch {
            warn "$id list update failed: $_";
        }
    }
    return $h;
}

1;
