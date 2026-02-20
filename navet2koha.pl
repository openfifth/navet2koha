#!/usr/bin/perl 

# Copyright 2019 Magnus Enger Libriotech

=head1 NAME

navet2koha.pl - Syncronize patron data from Navet to Koha.

=head1 SYNOPSIS

 sudo PERL5LIB=/usr/share/koha/lib/ KOHA_CONF=/etc/koha/sites/mykoha/koha-conf.xml perl my_script.pl --configfile /path/to/config.yaml -v

=head1 NON-STANDARD DEPENDENCIES

  sudo cpanm Se::PersonNr

=head1 SAMPLE DATA

This is an example of data returned from the API:

  <?xml version='1.0' encoding='UTF-8'?>
  <S:Envelope xmlns:S="http://schemas.xmlsoap.org/soap/envelope/">
    <S:Body>
      <ns0:PersonpostXMLResponse 
        xmlns:ns1="http://www.skatteverket.se/folkbokforing/na/personpostXML/v2" 
        xmlns:ns0="http://xmls.skatteverket.se/se/skatteverket/folkbokforing/na/epersondata/V1">
        <ns0:Folkbokforingsposter>
          <Folkbokforingspost>
            <Arendeuppgift andringstidpunkt="20200406121712"/>
            <Personpost>
              <PersonId>
                <PersonNr>************</PersonNr>
              </PersonId>
              <Namn>
                <Tilltalsnamnsmarkering>10</Tilltalsnamnsmarkering>
                <Fornamn>Medel</Fornamn>
                <Mellannamn>Meddel</Mellannamn>
                <Efternamn>Svensson</Efternamn>
              </Namn>
              <Adresser>
                <Folkbokforingsadress>
                  <Utdelningsadress2>KUNGSGATAN 1</Utdelningsadress2>
                  <PostNr>64136</PostNr>
                  <Postort>KATRINEHOLM</Postort>
                </Folkbokforingsadress>
                <UUID>
                  <Fastighet>...</Fastighet>
                  <Adress>...</Adress>
                  <Lagenhet>...</Lagenhet>
                </UUID>
              </Adresser>
            </Personpost>
          </Folkbokforingspost>
        </ns0:Folkbokforingsposter>
      </ns0:PersonpostXMLResponse>
    </S:Body>
  </S:Envelope>

=cut

# Uncomment the line below to get debug output from the SOAP dialogue 
# with Navet, including a dump of all data received as XML.
# use SOAP::Lite ( +trace => 'all', readable => 1, outputxml => 1, );

use Navet::ePersondata::Personpost;
# use Se::PersonNr;
use Getopt::Long;
use Data::Dumper;
$Data::Dumper::Sortkeys = 1;
use Template;
use DateTime;
use Try::Tiny;
use YAML::Syck;
use Pod::Usage;
use Modern::Perl;
binmode STDOUT, ":utf8";

use FindBin qw($Bin);
use lib "$Bin/lib";
use Util;

use Koha::Patrons;
use Koha::Patron::Attributes;

my $dt = DateTime->now;

# Get options
my ( $borrowernumbers, $configfile, $capture_names, $limit, $offset, $test_mode, $verbose, $debug ) = get_options();

# Get the config from file and add verbose and debug to it
if ( !-e $configfile ) { die "The file $configfile does not exist..."; }
my $config = LoadFile( $configfile );
$config->{'verbose'} = $verbose;
$config->{'debug'}   = $debug;

# Set up a file for capturing names
my $names;
if ( $capture_names ) {
    open( $names, '>>', $capture_names ) or die "Could not open file '$capture_names' $!";
}

# Set up logging if requested
my $log;
if ( defined $config->{'logdir'} ) {
    my $filename = 'navet2koha-' . $dt->ymd('-') . 'T' . $dt->hms('') . '.log';
    my $logpath = $config->{'logdir'} . '/' . $filename;
    open( $log, '>>', $logpath ) or die "Could not open file '$logpath' $!";
} elsif ( defined $config->{'logfile'} ) {
    my $logpath = $config->{'logfile'};
    open( $log, '>>', $logpath ) or die "Could not open file '$logpath' $!";
}

say $log "!!! Running in test mode, no data in Koha will be changed/updated!" if $test_mode && $config->{'verbose'};

my $ep = Navet::ePersondata::Personpost->new(
    # Set proxy to test service instead of production 
#    soap_options => {
#        proxy => 'https://www2.test.skatteverket.se/na/na_epersondata/V2/personpostXML'
#    },
    pkcs12_file     => $config->{ 'pkcs12_file' },
    pkcs12_password => $config->{ 'pkcs12_password' },
    OrgNr           => $config->{ 'OrgNr' },
    BestallningsId  => $config->{ 'BestallningsId' },
);

# Turn a list of borrowernumbers into a list of borrowers
if ( $borrowernumbers ) {

    my @borrnums = split /,/, $borrowernumbers;
    BORRNUM: foreach my $borrowernumber ( @borrnums ) {
        say $log "\n*** Looking at borrowernumber=$borrowernumber ***" if $config->{'verbose'};
        my $patron = Koha::Patrons->find({ borrowernumber => $borrowernumber });
        unless ( $patron ) {
            say $log "Patron not found for borrowernumber=$borrowernumber" if $config->{'verbose'};
            next BORRNUM;
        }
        say $log "Looking..." if $config->{'verbose'};
        _process_borrower( $patron );
        say $log "Done." if $config->{'verbose'};
    }

} else {

    my $count = 0;
    my $patrons;
    if ( defined $config->{ 'categorycodes' } ) {
        # Limit search to given categorycodes
        $patrons = Koha::Patrons->search({
            categorycode => {
                -in => [ @{ $config->{ 'categorycodes' } } ]
            }
        });
    } else {
        # Process all patrons
        $patrons = Koha::Patrons->search();
    }
    say $log "Patrons found: " . $patrons->count if $config->{'verbose'};
    PATRON: while ( my $patron = $patrons->next ) {
        $count++;
        say $log "*** $count Looking at borrowernumber=" . $patron->borrowernumber . "***" if $config->{'verbose'};
        say $log "categorycode: " . $patron->categorycode if $config->{'verbose'};
        # Implement --offset
        next PATRON if $offset && $count < $offset;
        _process_borrower( $patron );
        # Implement --limit
        last PATRON if $limit && $count == $limit;
    }

}

say $log "Done at " . $dt->ymd('-') . 'T' . $dt->hms('') if $config->{'verbose'};

sub _process_borrower {

    my ( $borrower ) = @_;

    ## Check the social security number makes sense
    my $socsec;

    if ( defined $config->{'socsec_attribute'} && $config->{'socsec_attribute'} ne '' ) {

        # Get the social security attribute
        my $socsec_attr = Koha::Patron::Attributes->search({
            'borrowernumber' => $borrower->borrowernumber,
            'code'           => $config->{ 'socsec_attribute' },
        });

        # Check that we got an attribute
        unless ( $socsec_attr && $socsec_attr->count ) {
            say $log "Personnummer not found" if $config->{'verbose'};
            return undef;
        } else {
            say $log "Personnummer found" if $config->{'verbose'};
        }

        # Extract the literal social security number
        $socsec = $socsec_attr->next->attribute;

    } else {

        # Default: Use the userid as social security number
        $socsec = $borrower->userid;

    }

    # Remove any whitespace
    $socsec =~ s/\s//g;

    # Check for letters in the social security number
    if ( $socsec =~ m/\D/g ) {
        say $log "FAIL $socsec Contains illegal character" if $config->{'verbose'};
        return undef;
    }

    # Check the length of the social security number, it should be 12 digits
    if ( length $socsec != 12 ) {
        say $log "FAIL $socsec Wrong length" if $config->{'verbose'};
        return undef;
    } else {
        say $log "Correct length" if $config->{'verbose'};
    }

    # Try to parse the number with Se::PersonNr, this should check that the
    # cheksum is correct, etc
    # It looks like this module has a 9 year old problem with checking if personnummer
    # are valid: https://rt.cpan.org/Public/Bug/Display.html?id=83201
    # my $pnr = new Se::PersonNr( $socsec );
    # if ( ! $pnr->is_valid() ) {
    #     say $log "FAIL $socsec Rejected by Se::PersonNr (checksum should be ". $pnr->get_valid() . ")" if $config->{'verbose'};
    #     return undef;
    # } else {
    #     say $log "Accepted by Se::PersonNr" if $config->{'verbose'};
    # }

    # If we got this far, try to get the actual data from Navet
    my $node;
    try {
        say $log "Looking up PersonId => $socsec" if $config->{'verbose'};
        $node = $ep->find_first({ PersonId => $socsec });
        say $log "Done looking up" if $config->{'verbose'};
    } catch {
        warn "caught error: $_"; # not $@
    };
    if ( my $err = $ep->error) {
        say $log "Error:" if $config->{'verbose'};
        say $log 'message: ' .          $err->{message}          if $err->{message}          && $config->{'verbose'}; # error text
        say $log 'soap_faultcode: ' .   $err->{soap_faultcode}   if $err->{soap_faultcode}   && $config->{'verbose'}; # SOAP faultcode from /Envelope/Body/Fault/faultscode
        say $log 'soap_faultstring: ' . $err->{soap_faultstring} if $err->{soap_faultstring} && $config->{'verbose'}; # SOAP faultstring from /Envelope/BodyFault/faultstring
        say $log 'sv_Felkod: ' .        $err->{sv_Felkod}        if $err->{sv_Felkod}        && $config->{'verbose'}; # Extra error code provided by Skatteverket
        say $log 'sv_Beskrivning: ' .   $err->{sv_Beskrivning}   if $err->{sv_Beskrivning}   && $config->{'verbose'}; # Extra description provided by Skatteverket
        say $log 'raw_error: ' .        $err->{raw_error}        if $err->{raw_error}        && $config->{'verbose'}; # Unparsed error text (can be XML, HTML or plain text)
        say $log 'https_status: ' .     $err->{https_status}     if $err->{https_status}     && $config->{'verbose'}; # HTTP status code
    }

    # say $log "Do we have a node?" if $config->{'verbose'};
    return undef unless $node;
    # say $log "We have a node" if $config->{'verbose'};
    # say $log Dumper join ' ', $node->findvalue('./Personpost/Namn/Fornamn') if $config->{'verbose'};

    # Update SKYDDAD with Navet Sekretessmarkering
    _update_patron_attribute(
        $borrower,
        $node->findvalue('./Sekretessmarkering'),
        $config->{ 'protected_attribute' }
    );

    # Some patrons have a hidden address. These should not be updated with data
    # from Navet. Such patrons should have an extended patron attribute set to 1.
    # The name of the attribute is specified by the "protected_attribute" config
    # variable.
    my $protected = Koha::Patron::Attributes->search({
        'borrowernumber' => $borrower->borrowernumber,
        'code'           => $config->{ 'protected_attribute' },
    });
    if ( $protected && $protected->count > 0 && $protected->next->attribute eq 'J' ) {
        say $log "Protected patron" if $config->{'verbose'};
        return undef;
    } else {
        say $log "Not protected" if $config->{'verbose'};
    }

    if ( $capture_names ) {

        say $names '"' . $node->findvalue( './Personpost/Namn/Fornamn' ) . '","' . $node->findvalue( './Personpost/Namn/Mellannamn' ) . '","' . $node->findvalue( './Personpost/Namn/Efternamn' ) . '","' . $node->findvalue( './Personpost/Namn/Tilltalsnamnsmarkering' ) . '"';

    } else {
        # Walk through the data and see if Koha and Navet differ
        my $is_changed = 0;
        foreach my $key ( sort keys %{ $config->{ 'patronmap' } } ) {

            my $navet_value;
            if ( ref $config->{ 'patronmap' }->{ $key } eq 'ARRAY' ) {
                foreach my $element ( @{ $config->{ 'patronmap' }->{ $key } } ) {
                    if ( $navet_value ) {
                        $navet_value .= ' ' . $node->findvalue( $element );
                    } else {
                        $navet_value .= $node->findvalue( $element );
                    }
                }
            } else {
                $navet_value = $node->findvalue( $config->{ 'patronmap' }->{ $key } );
            }

            # Check if Fornamn (firstname) needs to be reduced to Tilltalsnamn (preferred name)
            if ( $key eq 'firstname' &&
                 defined $config->{'use_tilltalsnamn'} &&
                 $config->{'use_tilltalsnamn'} == 1 &&
                 $node->findvalue( './Personpost/Namn/Tilltalsnamnsmarkering' ) ne ''
            ) {
                $navet_value = Util::get_tilltalsnamn(
                    $node->findvalue( './Personpost/Namn/Fornamn' ),
                    $node->findvalue( './Personpost/Namn/Tilltalsnamnsmarkering' )
                );
                say $log $node->findvalue( './Personpost/Namn/Tilltalsnamnsmarkering' ) . ' ' .
                         $node->findvalue( './Personpost/Namn/Fornamn' ) . ' => ' .
                         $navet_value if $config->{'verbose'};
            }

            print $log $key . ' Koha="' . $borrower->$key . '" <=> Navet="' . $navet_value . '"' if $config->{'verbose'};
            if ( $borrower->$key eq $navet_value ) {
                print $log ' -> equal' if $config->{'verbose'};
            } else {
                print $log ' -> NOT equal' if $config->{'verbose'};
                $is_changed = 1;
                # Update the object
                $borrower->$key( $navet_value );
            }
            print $log "\n" if $config->{'verbose'};
        
        }

        if ($config->{'avreg_attribute'}) {
            _update_patron_attribute(
                $borrower, 
                $node->findvalue('./Personpost/Avregistrering/AvregistreringsorsakKod'),
                $config->{'avreg_attribute'}
            );
        }

        # Only save if we have some changes
        if ( $is_changed == 1 ) {
            say $log "Going to update borrower with borrowernumber=" . $borrower->borrowernumber if $config->{'verbose'};
            if ( $test_mode == 0 ) {
                $borrower->store;
            } else {
                say $log "Running in test mode, not updating" if $config->{'verbose'};
            }
            say $log "Done" if $config->{'verbose'};
        }

    }

}

=head2 _update_patron_attribute

Generalized helper to update a patron attribute with contents from XML.
Returns 1 if a change was made, 0 otherwise.

=cut

sub _update_patron_attribute {
    my ( $borrower, $navet_value, $attr_code ) = @_;
    
    return 0 unless $attr_code;

    my $attribute_type = Koha::Patron::Attribute::Types->find($attr_code);
    unless ($attribute_type) {
        say $log "Configuration Error: Attribute code '$attr_code' does not exist in Koha." if $config->{'verbose'};
        return 0;
    }

    if ( defined $navet_value && $navet_value ne '' ) {
        
        my $existing_attr = Koha::Patron::Attributes->find({
            borrowernumber => $borrower->borrowernumber,
            code           => $attr_code
        });

        if (!$existing_attr){
            say $log "Adding Attribute [$attr_code]: Koha='(empty)' -> Navet='$navet_value'" if $config->{'verbose'};
            if ( $test_mode == 0 ) {
                $borrower->add_extended_attribute(
                    { code => $attr_code, attribute => $navet_value },
                );
            } else {
                say $log "TEST MODE: Skipping update for $attr_code" if $config->{'verbose'};
            }
        } elsif($existing_attr->attribute ne $navet_value){
            say $log "Updating Attribute [$attr_code]: Koha='" . ($existing_attr ? $existing_attr->attribute : 'NULL') . "' -> Navet='$navet_value'" if $config->{'verbose'};
            if ( $test_mode == 0 ) {
                $existing_attr->attribute($navet_value)->store;
            } else {
                say $log "TEST MODE: Skipping update for $attr_code" if $config->{'verbose'};
            }
            return 1;
        }
    }
    
    return 0;
}

=head1 OPTIONS

=over 4

=item B<-b, --borrowernumbers>

One or more borrowernumbers to look up. If more than one borrowernumber is given,
they should be separated by commas, without any spaces. Example:

  --borrowernumbers 123456789,234567890

=item B<-c, --configfile>

Path to config file in YAML format.

=item B<--capture_names>

Path to file where names from Navet should be captured.

Navet provides separate fields for firstname, middlename and surname. It might
necessary to inspect how names are split across these fields. If B<--capture_names>
is enabled, no updates will be made, but names will be written to a comma separated
file, with the path given as argument to this option.

=item B<-l, --limit>

Only process the n first patrons. Does not work with --borrowernumbers.

=item B<-o, --offset>

Skip the n first patrons. Does not work with --borrowernumbers.

=item B<-t, --test>

Run in test mode. No data will be changed/saved in Koha.

=item B<-v --verbose>

More verbose output.

=item B<-d --debug>

Even more verbose output.

=item B<-h, -?, --help>

Prints this help message and exits.

=back

=cut

sub get_options {

    # Options
    my $borrowers     = '';
    my $configfile    = '';
    my $capture_names = '';
    my $limit         = '';
    my $offset        = '';
    my $test_mode     = 0;
    my $verbose       = '';
    my $debug         = '';
    my $help          = '';

    GetOptions (
        'b|borrowernumbers=s' => \$borrowers,
        'c|configfile=s'      => \$configfile,
        'capture_names=s'     => \$capture_names,
        'l|limit=i'           => \$limit,
        'o|offset=i'          => \$offset,
        't|test'              => \$test_mode,
        'v|verbose'           => \$verbose,
        'd|debug'             => \$debug,
        'h|?|help'            => \$help
    );

    pod2usage( -exitval => 0 ) if $help;
    pod2usage( -msg => "\nMissing Argument: -c, --configfile required\n", -exitval => 1 ) if !$configfile;

    return ( $borrowers, $configfile, $capture_names, $limit, $offset, $test_mode, $verbose, $debug );

}

=head1 AUTHOR

Magnus Enger, <magnus [at] libriotech.no>

=head1 LICENSE

 This program is free software: you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation, either version 3 of the License, or
 (at your option) any later version.
 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.
 You should have received a copy of the GNU General Public License
 along with this program.  If not, see <http://www.gnu.org/licenses/>.

=cut
