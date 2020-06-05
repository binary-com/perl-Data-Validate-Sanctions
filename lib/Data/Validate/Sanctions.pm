package Data::Validate::Sanctions;

use strict;
use warnings;

require Exporter;
our @ISA       = qw(Exporter);
our @EXPORT_OK = qw/is_sanctioned set_sanction_file get_sanction_file/;

use Carp;
use Data::Validate::Sanctions::Fetcher;
use File::stat;
use File::ShareDir;
use YAML::XS qw/DumpFile LoadFile/;
use Scalar::Util qw(blessed);
use Date::Utility;
use List::Util qw(any uniq max min);

our $VERSION = '0.11';

my $sanction_file = _default_sanction_file();
my $instance;

# for OO
sub new {    ## no critic (RequireArgUnpacking)
    my ($class, %args) = @_;

    my $self = {};
    $self->{sanction_file} = $args{sanction_file} // _default_sanction_file();

    $self->{args} = {%args};

    $self->{last_time} = 0;
    return bless $self, ref($class) || $class;
}

sub update_data {
    my $self = shift;

    my $new_data = Data::Validate::Sanctions::Fetcher::run($self->{args}->%*);

    my $updated;
    foreach my $k (keys %$new_data) {
        if (ref($self->{_data}{$k}) ne 'HASH' || $self->{_data}{$k}{updated} < $new_data->{$k}{updated}) {
            $self->{_data}{$k} = $new_data->{$k};
            $updated = 1;
        }
    }

    $self->_save_data if $updated;
    return;
}

sub last_updated {
    my $self = shift;
    my $list = shift;

    if ($list) {
        return $self->{_data}->{$list}->{updated};
    } else {
        $self->_load_data();
        return max(map { $_->{updated} } values %{$self->{_data}});
    }
}

sub set_sanction_file {    ## no critic (RequireArgUnpacking)
    $sanction_file = shift // die "sanction_file is needed";
    undef $instance;
    return;
}

sub get_sanction_file {
    return $instance ? $instance->{sanction_file} : $sanction_file;
}

sub is_sanctioned {        ## no critic (RequireArgUnpacking)
    return (get_sanctioned_info(@_))->{matched};
}

sub get_sanctioned_info {    ## no critic (RequireArgUnpacking)
    my $self = blessed($_[0]) ? shift : $instance;

    my ($first_name, $last_name, $date_of_birth) = @_;

    unless ($self) {
        $instance = __PACKAGE__->new(sanction_file => $sanction_file);
        $self = $instance;
    }

    my $data = $self->_load_data();

    # Sub to remove non-alphabets from the name
    my $clean_names = sub {

        my ($full_name) = @_;

        # Remove non-alphabets
        my @cleaned_full_name = split " ", uc($full_name =~ s/[^[:alpha:]\s]//gr);

        return @cleaned_full_name;
    };

    my $client_full_name = join(' ', $first_name, $last_name || ());

    # Split into tokens after cleaning
    my @client_name_tokens = $clean_names->($client_full_name);

    my $matched_name;
    my $matched_file;
    my @match_with_dob_text;

    for my $file (sort keys %$data) {

        my @names = keys %{$data->{$file}->{names_list}};

        foreach my $sanctioned_name (sort @names) {

            my @sanctioned_name_tokens = $clean_names->($sanctioned_name);

            next unless _name_matches(\@client_name_tokens, \@sanctioned_name_tokens);

            my $checked_dob;

            # Some clients in sanction list can have more than one date of birth
            # Comparison is made using the epoch and year values
            my $client_dob_date  = Date::Utility->new($date_of_birth);
            my $client_dob_epoch = $client_dob_date->epoch;
            my $client_dob_year  = $client_dob_date->year;

            my $sanctions_epoch_list = $data->{$file}->{names_list}->{$sanctioned_name}->{dob_epoch} // [];

            $checked_dob = any { $_ eq $client_dob_epoch } @{$sanctions_epoch_list};
            return _possible_match($file, $sanctioned_name, 'Date of birth matches', $date_of_birth) if $checked_dob;

            my $sanctions_year_list  = $data->{$file}->{names_list}->{$sanctioned_name}->{dob_year}  // [];

            $checked_dob = any { $_ eq $client_dob_year } @{$sanctions_year_list};
            return _possible_match($file, $sanctioned_name, 'Year of birth matches', $client_dob_year) if $checked_dob;

            # Saving names with dob_text for later check.
            my $has_no_epoch_or_year = (@$sanctions_epoch_list || @$sanctions_year_list) ? 0 : 1;
            my $has_dob_text = @{$data->{$file}->{names_list}->{$sanctioned_name}->{dob_text} // []} ? 1 : 0;
            if ($has_dob_text || $has_no_epoch_or_year) {
                push @match_with_dob_text,
                    {
                    name => $sanctioned_name,
                    file => $file
                    };
            }
        }
    }

    # Return a possible match if the name matches and no date of birth is present in sanctions
    for my $match (@match_with_dob_text) {
        # We match only in case we have full match for the name
        # in other case we may get too many false positives
        my ($sacntion_name, $client_name) = map { uc(s/[^[:alpha:]\s]//gr) } ($match->{name}, $client_full_name);

        next unless $sacntion_name eq $client_name;

        my $dob_text = $data->{$match->{file}}{names_list}{$match->{name}}{dob_text} // [];

        my $reason = 'Name is similar';

        if (@$dob_text) {
            $reason .= ' - dob raw text: ' . join q{, } => @$dob_text;
        }

        return _possible_match($match->{file}, $match->{name}, $reason, 'N/A');
    }

    # Return if no possible match, regardless if date of birth is provided or not
    return {matched => 0};
}

sub _load_data {
    my $self          = shift;
    my $sanction_file = $self->{sanction_file};
    $self->{last_time} //= 0;
    $self->{_data} //= {};

    if (-e $sanction_file) {
        return $self->{_data} if stat($sanction_file)->mtime <= $self->{last_time} && $self->{_data};
        $self->{last_time} = stat($sanction_file)->mtime;
        $self->{_data}     = LoadFile($sanction_file);
    }
    return $self->{_data};
}

sub _save_data {
    my $self = shift;

    my $sanction_file     = $self->{sanction_file};
    my $new_sanction_file = $sanction_file . ".tmp";

    DumpFile($new_sanction_file, $self->{_data});

    rename $new_sanction_file, $sanction_file or die "Can't rename $new_sanction_file to $sanction_file, please check it\n";
    $self->{last_time} = stat($sanction_file)->mtime;
    return;
}

sub _default_sanction_file {
    return $ENV{SANCTION_FILE} // File::ShareDir::dist_file('Data-Validate-Sanctions', 'sanctions.yml');
}

sub _possible_match {
    return +{
        matched     => 1,
        list        => $_[0],
        name        => $_[1],
        reason      => $_[2],
        matched_dob => $_[3]};
}

sub _name_matches {
    my ($small_tokens_list, $bigger_tokens_list) = @_;

    my $name_matches_count = 0;

    foreach my $token (@$small_tokens_list) {
        $name_matches_count++ if any { $_ eq $token } @$bigger_tokens_list;
    }

    my $small_tokens_size = min(scalar(@$small_tokens_list), scalar(@$bigger_tokens_list));

    # - If more than one word matches, return it as possible match
    # - Some sanctioned individuals have only one name (ex. Hamza); this should be returned as well
    return 1 if ($name_matches_count > 1) || ($name_matches_count == 1 && $small_tokens_size == 1);

    return 0;
}

1;
__END__

=encoding utf-8

=head1 NAME

Data::Validate::Sanctions - Validate a name against sanctions lists

=head1 SYNOPSIS

    # as exported function
    use Data::Validate::Sanctions qw/is_sanctioned get_sanction_file set_sanction_file/;
    set_sanction_file('/var/storage/sanction.csv');

    my ($first_name, $last_name) = ("First", "Last Name");
    print 'BAD' if is_sanctioned($first_name, $last_name);

    # as OO
    use Data::Validate::Sanctions;

    #You can also set sanction_file in the new method.
    my $validator = Data::Validate::Sanctions->new(sanction_file => '/var/storage/sanction.csv');
    print 'BAD' if $validator->is_sanctioned("$last_name $first_name");

=head1 DESCRIPTION

Data::Validate::Sanctions is a simple validitor to validate a name against sanctions lists.

The list is from L<https://www.treasury.gov/ofac/downloads/sdn.csv>, L<https://www.treasury.gov/ofac/downloads/consolidated/cons_prim.csv>

run F<update_sanctions_csv> to update the bundled csv.

The path of list can be set by function L</set_sanction_file> or by method L</new>. If not set, then environment variable $ENV{SANCTION_FILE} will be checked, at last
the default file in this package will be used.

=head1 METHODS

=head2 is_sanctioned

    is_sanctioned($last_name, $first_name);
    is_sanctioned($first_name, $last_name);
    is_sanctioned("$last_name $first_name");

when one string is passed, please be sure last_name is before first_name.

or you can pass first_name, last_name (last_name, first_name), we'll check both "$last_name $first_name" and "$first_name $last_name".

retrun 1 if match is found and 0 if match is not found.

It will remove all non-alpha chars and compare with the list we have.

=head2 get_sanctioned_info

    my $result =get_sanctioned_info($last_name, $first_name, $date_of_birth);
    print 'match: ', $result->{name}, ' on list ', $result->{list} if $result->{matched};

return hashref with keys:
    matched      1 or 0, depends if name has matched
    list       name of list matched (present only if matched)
    name        name of sanctioned person matched (present only if matched)

It will remove all non-alpha chars and compare with the list we have.

=head2 update_data

Fetches latest versions of sanction lists, and updates corresponding sections of stored file, if needed

=head2 last_updated

Returns timestamp of when the latest list was updated.
If argument is provided - return timestamp of when that list was updated.

=head2 new

Create the object, and set sanction_file

    my $validator = Data::Validate::Sanctions->new(sanction_file => '/var/storage/sanction.csv');

=head2 get_sanction_file

get sanction_file which is used by L</is_sanctioned> (procedure-oriented)

=head2 set_sanction_file

set sanction_file which is used by L</is_sanctioned> (procedure-oriented)

=head2 _name_matches

Pass in the client's name and sanctioned individual's name to see if they are similar or not

=head1 AUTHOR

Binary.com E<lt>fayland@binary.comE<gt>

=head1 COPYRIGHT

Copyright 2014- Binary.com

=head1 LICENSE

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 SEE ALSO

L<Data::OFAC>

=cut
