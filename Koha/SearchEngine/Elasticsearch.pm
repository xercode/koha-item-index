package Koha::SearchEngine::Elasticsearch;

# Copyright 2015 Catalyst IT
#
# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.
#
# Koha is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Koha; if not, see <https://www.gnu.org/licenses>.

use base qw(Class::Accessor);

use C4::Context;

use Koha::Database;
use Koha::Exceptions::Config;
use Koha::Exceptions::Elasticsearch;
use Koha::Filter::MARC::EmbedSeeFromHeadings;
use Koha::I18N qw(__);
use Koha::SearchFields;
use Koha::SearchMarcMaps;
use Koha::Caches;
use Koha::AuthorisedValueCategories;
use C4::Heading;
use C4::AuthoritiesMarc qw( GuessAuthTypeCode );
use C4::Biblio;
use Koha::Biblios;
use Koha::Biblioitems;
use Koha::Items;
use Koha::Item::Transfers;
use Koha::Holds;
use Koha::Libraries;
use Koha::Logger;

use Carp  qw( carp croak );
use Clone qw( clone );
use Modern::Perl;
use Readonly qw( Readonly );
use Search::Elasticsearch;
use Search::Elasticsearch::Role::Cxn;
{
    # Monkey-patch Search::Elasticsearch::Role::Cxn::process_response
    no warnings 'redefine';

    my $orig_sub = \&Search::Elasticsearch::Role::Cxn::process_response;

    # Override method
    *Search::Elasticsearch::Role::Cxn::process_response = sub {
        my ( $self, $params, $code, $msg, $body, $headers ) = @_;

        unless ( $headers && $headers->{'x-elastic-product'} && $headers->{'x-elastic-product'} eq 'Elasticsearch' ) {
            $Search::Elasticsearch::Role::Cxn::PRODUCT_CHECK_VALUE = '';
        }
        $orig_sub->(@_);
    };
}

use Try::Tiny qw( catch try );
use JSON::PP  ();
use YAML::XS;

use List::Util qw( sum0 );
use MARC::Field;
use MARC::File::XML;
use MARC::Record;
use MIME::Base64 qw( encode_base64 );
use Encode       qw( encode );
use Business::ISBN;
use Scalar::Util qw( looks_like_number );

__PACKAGE__->mk_ro_accessors(qw( index index_name ));
__PACKAGE__->mk_accessors(qw( sort_fields ));

# Constants to refer to the standard index names
Readonly our $BIBLIOS_INDEX     => 'biblios';
Readonly our $AUTHORITIES_INDEX => 'authorities';

# Version of the nested items schema (Bug XXXXX), written to the
# items_schema_version field of every catalogued record. It tells the documents
# indexed before a change to the items schema apart, e.g. to fill a new item
# subfield from items.marc in place, without reindexing. Version 1 introduces
# items.marc.
Readonly our $ITEMS_SCHEMA_VERSION => 1;

=head1 NAME

Koha::SearchEngine::Elasticsearch - Base module for things using elasticsearch

=head1 ACCESSORS

=over 4

=item index

The name of the index to use, generally 'biblios' or 'authorities'.

=item index_name

The Elasticsearch index name with Koha instance prefix.

=back


=head1 FUNCTIONS

=cut

=head2 new

Missing POD for new.

=cut

sub new {
    my $class = shift @_;
    my ($params) = @_;

    # Check for a valid index
    Koha::Exceptions::MissingParameter->throw('No index name provided') unless $params->{index};
    my $config = _read_configuration();
    $params->{index_name} = $config->{index_name} . '_' . $params->{index};

    my $self = $class->SUPER::new(@_);
    return $self;
}

=head2 get_elasticsearch

    my $elasticsearch_client = $self->get_elasticsearch();

Returns a C<Search::Elasticsearch> client. The client is cached on a C<Koha::SearchEngine::ElasticSearch>
instance level and will be reused if method is called multiple times.

=cut

sub get_elasticsearch {
    my $self = shift @_;
    unless ( defined $self->{elasticsearch} ) {
        $self->{elasticsearch} = Search::Elasticsearch->new( $self->get_elasticsearch_params() );
    }
    return $self->{elasticsearch};
}

=head2 get_elasticsearch_params

    my $params = $self->get_elasticsearch_params();

This provides a hashref that contains the parameters for connecting to the
ElasicSearch servers, in the form:

    {
        'nodes' => ['127.0.0.1:9200', 'anotherserver:9200'],
        'index_name' => 'koha_instance_index',
    }

This is configured by the following in the C<config> block in koha-conf.xml:

    <elasticsearch>
        <server>127.0.0.1:9200</server>
        <server>anotherserver:9200</server>
        <index_name>koha_instance</index_name>
    </elasticsearch>

=cut

sub get_elasticsearch_params {
    my ($self) = @_;

    my $conf;
    try {
        $conf = _read_configuration();
    } catch {
        if ( ref($_) eq 'Koha::Exceptions::Config::MissingEntry' ) {
            croak( $_->message );
        }
    };

    return $conf;
}

=head2 get_elasticsearch_settings

    my $settings = $self->get_elasticsearch_settings();

This provides the settings provided to Elasticsearch when an index is created.
These can do things like define tokenization methods.

A hashref containing the settings is returned.

=cut

sub get_elasticsearch_settings {
    my ($self) = @_;

    # Use state to speed up repeated calls
    state $settings = undef;
    if ( !defined $settings ) {
        my $config_file = C4::Context->config('elasticsearch_index_config');
        $config_file ||= C4::Context->config('intranetdir') . '/admin/searchengine/elasticsearch/index_config.yaml';
        $settings = YAML::XS::LoadFile($config_file);
    }

    return $settings;
}

=head2 get_elasticsearch_mappings

    my $mappings = $self->get_elasticsearch_mappings();

This provides the mappings that get passed to Elasticsearch when an index is
created.

=cut

sub get_elasticsearch_mappings {
    my ($self) = @_;

    # Use state to speed up repeated calls
    state %all_mappings;
    state %sort_fields;

    if ( !defined $all_mappings{ $self->index } ) {
        $sort_fields{ $self->index } = {};

        # Clone the general mapping to break ties with the original hash
        my $mappings    = clone( _get_elasticsearch_field_config( 'general', '' ) );
        my $marcflavour = lc C4::Context->preference('marcflavour');
        $self->_foreach_mapping(
            sub {
                my ( $name, $type, $facet, $suggestible, $sort, $search, $filter, $marc_type ) = @_;
                return if $marc_type ne $marcflavour;

                # TODO if this gets any sort of complexity to it, it should
                # be broken out into its own function.

                # TODO be aware of date formats, but this requires pre-parsing
                # as ES will simply reject anything with an invalid date.
                my $es_type = 'text';
                if ( $type eq 'boolean' ) {
                    $es_type = 'boolean';
                } elsif ( $type eq 'number' || $type eq 'sum' ) {
                    $es_type = 'integer';
                } elsif ( $type eq 'isbn' || $type eq 'stdno' ) {
                    $es_type = 'stdno';
                } elsif ( $type eq 'year' ) {
                    $es_type = 'year';
                } elsif ( $type eq 'callnumber' ) {
                    $es_type = 'cn_sort';
                } elsif ( $type eq 'geo_point' ) {
                    $es_type = 'geo_point';
                }

                if ( $type eq 'geo_point' ) {
                    $name =~ s/_(lat|lon)$//;
                }

                if ($search) {
                    $mappings->{properties}{$name} = _get_elasticsearch_field_config( 'search', $es_type );
                }

                if ($facet) {
                    $mappings->{properties}{ $name . '__facet' } = _get_elasticsearch_field_config( 'facet', $es_type );
                }
                if ($suggestible) {
                    $mappings->{properties}{ $name . '__suggestion' } =
                        _get_elasticsearch_field_config( 'suggestible', $es_type );
                }

                # Sort should be defined in mappings as 1 (Yes) or 0 (No)
                # Previously, we also supported ~ (Undef) in the file
                # "undef" means to do the default thing, which is make it sortable.
                # This is preserved in order to not cause breakages for existing installs
                if ( !defined $sort || $sort ) {
                    $mappings->{properties}{ $name . '__sort' } = _get_elasticsearch_field_config( 'sort', $es_type );
                    $sort_fields{ $self->index }{$name} = 1;
                }
            }
        );
        if ( $self->index eq 'authorities' ) {
            $mappings->{properties}{'match-heading'}             = _get_elasticsearch_field_config( 'search', 'text' );
            $mappings->{properties}{'subject-heading-thesaurus'} = _get_elasticsearch_field_config( 'search', 'text' );
        }

        # Nested item object (Bug XXXXX). The `items` field is a `nested` object
        # whose values are computed from the database at index time, so it is not
        # represented in the search_field / search_marc_map tables. Inject its
        # mapping directly from the dedicated 'item' section of field_config.yaml.
        if ( $self->index eq $BIBLIOS_INDEX ) {
            $mappings->{properties}{items} = clone( _get_elasticsearch_field_config( 'item', '' ) );

            # Mapped explicitly so that range queries on the version (see
            # $ITEMS_SCHEMA_VERSION) do not depend on dynamic mapping.
            $mappings->{properties}{items_schema_version} = { type => 'integer' };
        }

        # Disable date and numeric detection to prevent Elasticsearch from
        # auto-detecting field types in marc_data_array. Without this, a
        # subfield value that looks like a date (e.g. "2024-01-15") causes
        # ES to lock that subfield to type "date", and subsequent non-date
        # values fail to index. (Bug 42485)
        $mappings->{date_detection}    = JSON::PP::false;
        $mappings->{numeric_detection} = JSON::PP::false;

        $all_mappings{ $self->index } = $mappings;
    }
    $self->sort_fields( \%{ $sort_fields{ $self->index } } );
    return $all_mappings{ $self->index };
}

=head2 raw_elasticsearch_mappings

Return elasticsearch mapping as it is in database.
marc_type: marc21|unimarc

$raw_mappings = raw_elasticsearch_mappings( $marc_type )

=cut

sub raw_elasticsearch_mappings {
    my ($marc_type) = @_;

    my $schema = Koha::Database->new()->schema();

    my $search_fields = Koha::SearchFields->search( {}, { order_by => { -asc => 'name' } } );

    my $mappings = {};
    while ( my $search_field = $search_fields->next ) {

        my $marc_to_fields = $schema->resultset('SearchMarcToField')->search(
            { search_field_id => $search_field->id },
            {
                join     => 'search_marc_map',
                order_by => { -asc => [ 'search_marc_map.marc_type', 'search_marc_map.marc_field' ] }
            }
        );

        while ( my $marc_to_field = $marc_to_fields->next ) {

            my $marc_map = $marc_to_field->search_marc_map;

            next if $marc_type && $marc_map->marc_type ne $marc_type;

            $mappings->{ $marc_map->index_name }{ $search_field->name }{label}       = $search_field->label;
            $mappings->{ $marc_map->index_name }{ $search_field->name }{type}        = $search_field->type;
            $mappings->{ $marc_map->index_name }{ $search_field->name }{mandatory}   = $search_field->mandatory;
            $mappings->{ $marc_map->index_name }{ $search_field->name }{facet_order} = $search_field->facet_order
                if defined $search_field->facet_order;
            $mappings->{ $marc_map->index_name }{ $search_field->name }{authorised_value_category} =
                $search_field->authorised_value_category
                if defined $search_field->authorised_value_category;
            $mappings->{ $marc_map->index_name }{ $search_field->name }{weight} = $search_field->weight
                if defined $search_field->weight;
            $mappings->{ $marc_map->index_name }{ $search_field->name }{opac} = $search_field->opac
                if defined $search_field->opac;
            $mappings->{ $marc_map->index_name }{ $search_field->name }{staff_client} = $search_field->staff_client
                if defined $search_field->staff_client;

            push(
                @{ $mappings->{ $marc_map->index_name }{ $search_field->name }{mappings} },
                {
                    facet       => $marc_to_field->facet || '',
                    marc_type   => $marc_map->marc_type,
                    marc_field  => $marc_map->marc_field,
                    sort        => $marc_to_field->sort,
                    suggestible => $marc_to_field->suggestible || '',
                    filter      => $marc_to_field->filter      || ''
                }
            );

        }
    }

    return $mappings;
}

=head2 _get_elasticsearch_field_config

Get the Elasticsearch field config for the given purpose and data type.

$mapping = _get_elasticsearch_field_config('search', 'text');

=cut

sub _get_elasticsearch_field_config {

    my ( $purpose, $type ) = @_;

    # Use state to speed up repeated calls
    state $settings = undef;
    if ( !defined $settings ) {
        my $config_file = C4::Context->config('elasticsearch_field_config');
        $config_file ||= C4::Context->config('intranetdir') . '/admin/searchengine/elasticsearch/field_config.yaml';
        local $YAML::XS::Boolean = 'JSON::PP';
        $settings = YAML::XS::LoadFile($config_file);
    }

    if ( !defined $settings->{$purpose} ) {
        die "Field purpose $purpose not defined in field config";
    }
    if ( $type eq '' ) {
        return $settings->{$purpose};
    }
    if ( defined $settings->{$purpose}{$type} ) {
        return $settings->{$purpose}{$type};
    }
    if ( defined $settings->{$purpose}{'default'} ) {
        return $settings->{$purpose}{'default'};
    }
    return;
}

=head2 _load_elasticsearch_mappings

Load Elasticsearch mappings in the format of mappings.yaml.

$indexes = _load_elasticsearch_mappings();

=cut

sub _load_elasticsearch_mappings {
    my $mappings_yaml = C4::Context->config('elasticsearch_index_mappings');
    $mappings_yaml ||= C4::Context->config('intranetdir') . '/admin/searchengine/elasticsearch/mappings.yaml';
    return YAML::XS::LoadFile($mappings_yaml);
}

=head2 reset_elasticsearch_mappings

Missing POD for reset_elasticsearch_mappings.

=cut

sub reset_elasticsearch_mappings {
    my ($self) = @_;
    my $indexes = $self->_load_elasticsearch_mappings();

    Koha::SearchMarcMaps->delete;
    Koha::SearchFields->delete;

    while ( my ( $index_name, $fields ) = each %$indexes ) {
        while ( my ( $field_name, $data ) = each %$fields ) {

            my %sf_params =
                map  { $_ => $data->{$_} }
                grep { exists $data->{$_} }
                qw/ type label weight staff_client opac facet_order authorised_value_category mandatory/;

            # Set default values
            $sf_params{staff_client} //= 1;
            $sf_params{opac}         //= 1;

            $sf_params{name} = $field_name;

            my $search_field = Koha::SearchFields->find_or_create( \%sf_params, { key => 'name' } );

            my $mappings = $data->{mappings};
            for my $mapping (@$mappings) {
                my $marc_field = Koha::SearchMarcMaps->find_or_create(
                    {
                        index_name => $index_name,
                        marc_type  => $mapping->{marc_type},
                        marc_field => $mapping->{marc_field}
                    }
                );
                $search_field->add_to_search_marc_maps(
                    $marc_field,
                    {
                        facet       => $mapping->{facet}       || 0,
                        suggestible => $mapping->{suggestible} || 0,
                        sort        => $mapping->{sort}   // 1,
                        search      => $mapping->{search} // 1,
                        filter      => $mapping->{filter} // ''
                    }
                );
            }
        }
    }

    $self->clear_search_fields_cache();

    # FIXME return the mappings?
}

# This overrides the accessor provided by Class::Accessor so that if
# sort_fields isn't set, then it'll generate it.

=head2 sort_fields

Missing POD for sort_fields.

=cut

sub sort_fields {
    my $self = shift;
    if (@_) {
        $self->_sort_fields_accessor(@_);
        return;
    }
    my $val = $self->_sort_fields_accessor();
    return $val if $val;

    # This will populate the accessor as a side effect
    $self->get_elasticsearch_mappings();
    return $self->_sort_fields_accessor();
}

=head2 _process_mappings($mappings, $data, $record_document, $meta)

    $self->_process_mappings($mappings, $marc_field_data, $record_document, 0)

Process all C<$mappings> targets operating on a specific MARC field C<$data>.
Since we group all mappings by MARC field targets C<$mappings> will contain
all targets for C<$data> and thus we need to fetch the MARC field only once.
C<$mappings> will be applied to C<$record_document> and new field values added.
The method has no return value.

=over 4

=item C<$mappings>

Arrayref of mappings containing arrayrefs in the format
[C<$target>, C<$options>] where C<$target> is the name of the target field and
C<$options> is a hashref containing processing directives for this particular
mapping.

=item C<$data>

The source data from a MARC record field.

=item C<$record_document>

Hashref representing the Elasticsearch document on which mappings should be
applied.

=item C<$meta>

A hashref containing metadata useful for enforcing per mapping rules. For
example for providing extra context for mapping options, or treating mapping
targets differently depending on type (sort, search, facet etc). Combining
this metadata with the mapping options and metadata allows us to mutate the
data per mapping, or even replace it with other data retrieved from the
metadata context.

Current properties are:

C<altscript>: A boolean value indicating whether an alternate script presentation is being
processed.

C<data_source>: The source of the $<data> argument. Possible values are: 'leader', 'control_field',
'subfield' or 'subfields_group'.

C<code>: The code of the subfield C<$data> was retrieved, if C<data_source> is 'subfield'.

C<codes>: Subfield codes of the subfields group from which C<$data> was retrieved, if C<data_source>
is 'subfields_group'.

C<field>: The original C<MARC::Record> object.

=back

=cut

sub _process_mappings {
    my ( $_self, $mappings, $data, $record_document, $meta ) = @_;
    foreach my $mapping ( @{$mappings} ) {
        my ( $target, $options ) = @{$mapping};

        # Don't process sort fields for alternate scripts
        my $sort = $target =~ /__sort$/;
        if ( $sort && $meta->{altscript} ) {
            next;
        }

        # Copy (scalar) data since can have multiple targets
        # with differing options for (possibly) mutating data
        # so need a different copy for each
        my $data_copy = $data;
        if ( defined $options->{substr} ) {
            my ( $start, $length ) = @{ $options->{substr} };
            $data_copy = length($data) > $start ? substr $data_copy, $start, $length : '';
        }

        # Add data to values array for callbacks processing
        my $values = [$data_copy];

        # Value callbacks takes subfield data (or values from previous
        # callbacks) as argument, and returns a possibly different list of values.
        # Note that the returned list may also be empty.
        if ( defined $options->{value_callbacks} ) {
            foreach my $callback ( @{ $options->{value_callbacks} } ) {

                # Pass each value to current callback which returns a list
                # (scalar is fine too) resulting either in a list or
                # a list of lists that will be flattened by perl.
                # The next callback will receive the possibly expanded list of values.
                $values = [ map { $callback->($_) } @{$values} ];
            }
        }

        # Skip mapping if all values has been removed
        next unless @{$values};

        if ( defined $options->{property} ) {
            $values = [
                map {
                    { $options->{property} => $_ }
                    if $_
                } @{$values}
            ];
        }
        if ( defined $options->{nonfiling_characters_indicator} ) {
            my $nonfiling_chars = $meta->{field}->indicator( $options->{nonfiling_characters_indicator} );
            $nonfiling_chars = looks_like_number($nonfiling_chars) ? int($nonfiling_chars) : 0;

            # Nonfiling chars does not make sense for multiple values
            # Only apply on first element
            if ( $nonfiling_chars > 0 ) {
                if ($sort) {
                    $values->[0] = substr $values->[0], $nonfiling_chars;
                } else {
                    push @{$values}, substr $values->[0], $nonfiling_chars;
                }
            }
        }

        $values = [ grep( !/^$/, @{$values} ) ];

        # 4 bytes is the max size of a UTF-8 char.
        # 32766 bytes is the max size of the data ES can add to an index
        # 32766 / 4 =~ 8191
        my $MAX_SIZE = 8191;

        my @chunks;

        foreach my $value ( @{$values} ) {
            while ( length($value) > $MAX_SIZE ) {
                $value =~ s/^\s*//;

                # Match up to MAX_SIZE characters, stopping at the last full word before MAX_SIZE
                if ( $value =~ /\G(.{1,$MAX_SIZE})(?:\s|$)/g ) {
                    push @chunks, $1;
                    $value = substr( $value, length($1) );
                } else {

                    # Catch-all for very long words
                    push @chunks, substr( $value, 0, $MAX_SIZE );
                    $value = substr( $value, $MAX_SIZE );
                }
            }
            push @chunks, $value if length($value);
        }

        $record_document->{$target} //= [];
        push @{ $record_document->{$target} }, @chunks;
    }
}

=head2 marc_records_to_documents($marc_records)

    my $record_documents = $self->marc_records_to_documents($marc_records);

Using mappings stored in database convert C<$marc_records> to Elasticsearch documents.

Returns array of hash references, representing Elasticsearch documents,
acceptable as body payload in C<Search::Elasticsearch> requests.

For the biblios index, a record in the catalogue is indexed with the item fields
of its items in the database, whatever item fields it is passed with (Bug XXXXX):
the mappings and the C<elasticsearch_to_document> plugin hook get the record with
them, but the stored MARC (C<marc_data>, C<marc_data_array>) leaves them out.
Each item keeps its own field in C<items.marc> instead, and
C<Koha::SearchEngine::Elasticsearch::Search-E<gt>decode_record_from_result> adds
them back. So the records do not need their items embedded. A record that is not
in the catalogue is indexed as it is passed.

=over 4

=item C<$marc_documents>

Reference to array of C<MARC::Record> objects to be converted to Elasticsearch documents.

=back

=cut

sub marc_records_to_documents {
    my ( $self, $records ) = @_;
    my $rules                = $self->_get_marc_mapping_rules();
    my $control_fields_rules = $rules->{control_fields};
    my $data_fields_rules    = $rules->{data_fields};
    my $marcflavour          = lc C4::Context->preference('marcflavour');
    my $use_array            = C4::Context->preference('ElasticsearchMARCFormat') eq 'ARRAY';

    my @record_documents;

    my %auth_match_headings;
    if ( $self->index eq 'authorities' ) {
        my @auth_types = Koha::Authority::Types->search->as_list;
        %auth_match_headings = map { $_->authtypecode => $_->auth_tag_to_report } @auth_types;
    }

    # Build the nested item documents (Bug XXXXX) for the whole batch up front,
    # so transit/hold status and library geolocation are resolved with grouped
    # queries instead of one lookup per item inside the loop below.
    my $item_documents = {};
    my ( $biblionumber_tag, $biblionumber_code, $item_tag );
    if ( $self->index eq $BIBLIOS_INDEX ) {
        ( $biblionumber_tag, $biblionumber_code ) = C4::Biblio::GetMarcFromKohaField('biblio.biblionumber');
        ($item_tag) = C4::Biblio::GetMarcFromKohaField('items.itemnumber');
        my @biblionumbers;
        foreach my $record ( @{$records} ) {
            my $field = $record->field($biblionumber_tag);
            next unless $field;
            push @biblionumbers, $field->is_control_field ? $field->data : $field->subfield($biblionumber_code);
        }
        $item_documents = $self->_get_item_documents( \@biblionumbers );
    }

    foreach my $source_record ( @{$records} ) {
        my $record          = $source_record;
        my $record_document = {};

        # A record in the catalogue is indexed with the item fields of its
        # items in the database (Bug XXXXX), whatever item fields it comes
        # with: the mappings and the elasticsearch_to_document hook get them,
        # but the stored MARC leaves them out, as each item keeps its own in
        # items.marc. A record that is not in the catalogue has no items in the
        # database, and is indexed as it comes.
        my ( $biblionumber_field, $biblionumber, $catalogued );
        if ( $self->index eq $BIBLIOS_INDEX ) {
            $biblionumber_field = $record->field($biblionumber_tag);
            if ($biblionumber_field) {
                $biblionumber =
                      $biblionumber_field->is_control_field
                    ? $biblionumber_field->data
                    : $biblionumber_field->subfield($biblionumber_code);
                $catalogued = defined $biblionumber && exists $item_documents->{$biblionumber};
            }
        }
        if ($catalogued) {
            $record = MARC::Record->new;
            $record->leader( $source_record->leader );
            $record->append_fields( grep { $_->tag ne $item_tag } $source_record->fields );
            $self->_append_item_fields( $record, $item_documents->{$biblionumber} );
        }

        if ( $self->index eq 'authorities' ) {
            my $authtypecode = GuessAuthTypeCode($record);
            if ($authtypecode) {
                if ( $authtypecode !~ m/_SUBD/ )
                {    #Subdivision records will not be used for linking and so don't require match-heading to be built
                    my $field   = $record->field( $auth_match_headings{$authtypecode} );
                    my $heading = C4::Heading->new_from_field( $field, undef, 1 );         #new auth heading
                    push @{ $record_document->{'match-heading'} }, $heading->search_form if $heading;
                }
            } else {
                warn "Cannot determine authority type for record: " . $record->field('001')->as_string;
            }
        }

        my $mappings = $rules->{leader};
        if ($mappings) {
            $self->_process_mappings(
                $mappings,
                $record->leader(),
                $record_document,
                {
                    altscript   => 0,
                    data_source => 'leader'
                }
            );
        }
        foreach my $field ( $record->fields() ) {
            if ( $field->is_control_field() ) {
                my $mappings = $control_fields_rules->{ $field->tag() };
                if ($mappings) {
                    $self->_process_mappings(
                        $mappings,
                        $field->data(),
                        $record_document,
                        {
                            altscript   => 0,
                            data_source => 'control_field',
                            field       => $field
                        }
                    );
                }
            } else {
                my $tag = $field->tag();

                # Handle alternate scripts in MARC 21
                my $altscript = 0;
                if ( $marcflavour eq 'marc21' && $tag eq '880' ) {
                    my $sub6 = $field->subfield('6');
                    if ( $sub6 && $sub6 =~ /^(...)-\d+/ ) {
                        $tag       = $1;
                        $altscript = 1;
                    }
                }
                $self->_process_data_field_rules(
                    $data_fields_rules->{$tag},
                    $field,
                    $record_document,
                    $altscript
                );
            }
        }

        if (
            $self->index eq $BIBLIOS_INDEX
            and (  C4::Context->preference('IncludeSeeFromInSearches')
                || C4::Context->preference('IncludeSeeAlsoFromInSearches') )
            )
        {
            my $marc_filter = Koha::Filter::MARC::EmbedSeeFromHeadings->new;
            my @other_headings;
            if ( C4::Context->preference('IncludeSeeFromInSearches') ) {
                push @other_headings, 'see_from';
            }
            if ( C4::Context->preference('IncludeSeeAlsoFromInSearches') ) {
                push @other_headings, 'see_also_from';
            }

            $marc_filter->initialize( { options => { other_headings => \@other_headings } } );
            foreach my $field ( $marc_filter->fields($record) ) {
                $self->_process_data_field_rules(
                    $data_fields_rules->{ $field->tag() },
                    $field,
                    $record_document,
                    0,

                    # Do not include "see from" into these kind of fields
                    qr/__(sort|facet|suggestion)$/
                );
            }
        }

        foreach my $field ( keys %{ $rules->{defaults} } ) {
            unless ( defined $record_document->{$field} ) {
                $record_document->{$field} = $rules->{defaults}->{$field};
            }
        }
        foreach my $field ( @{ $rules->{sum} } ) {
            if ( defined $record_document->{$field} ) {

                # TODO: validate numeric? filter?
                # TODO: Or should only accept fields without nested values?
                # TODO: Quick and dirty, improve if needed
                $record_document->{$field} =
                    sum0( grep { !ref($_) && m/\d+(\.\d+)?/ } @{ $record_document->{$field} } );
            }
        }

        # Index all applicable ISBN forms (ISBN-10 and ISBN-13 with and without dashes)
        foreach my $field ( @{ $rules->{isbn} } ) {
            if ( defined $record_document->{$field} ) {
                my @isbns = ();
                foreach my $input_isbn ( @{ $record_document->{$field} } ) {
                    my $isbn = Business::ISBN->new($input_isbn);
                    if ( defined $isbn && $isbn->is_valid ) {
                        my $isbn13 = $isbn->as_isbn13->as_string;
                        push @isbns, $isbn13;
                        $isbn13 =~ s/\-//g;
                        push @isbns, $isbn13;

                        my $isbn10 = $isbn->as_isbn10;
                        if ($isbn10) {
                            $isbn10 = $isbn10->as_string;
                            push @isbns, $isbn10;
                            $isbn10 =~ s/\-//g;
                            push @isbns, $isbn10;
                        }
                    } else {
                        push @isbns, $input_isbn;
                    }
                }
                $record_document->{$field} = \@isbns;
            }
        }

        foreach my $field ( @{ $rules->{geo_point} } ) {
            next unless $record_document->{$field};
            my $geofield = $field;
            $geofield =~ s/_(lat|lon)$//;
            my $axis = $1;
            my $vals = $record_document->{$field};
            for my $i ( 0 .. @$vals - 1 ) {
                my $val = $record_document->{$field}[$i];
                $record_document->{$geofield}[$i]{$axis} = $val;
            }
            delete $record_document->{$field};
        }

        # Remove duplicate values and collapse sort fields
        foreach my $field ( keys %{$record_document} ) {
            if ( ref( $record_document->{$field} ) eq 'ARRAY' ) {
                @{ $record_document->{$field} } = do {
                    my %seen;
                    grep { !$seen{ ref($_) eq 'HASH' && defined $_->{input} ? $_->{input} : $_ }++ }
                        @{ $record_document->{$field} };
                };
                if ( $field =~ /__sort$/ ) {

                    # Make sure to keep the sort field length sensible. 255 was chosen as a nice round value.
                    $record_document->{$field} = [ substr( join( ' ', @{ $record_document->{$field} } ), 0, 255 ) ];
                }
            }
        }

        # TODO: Perhaps should check if $records_document non empty, but really should never be the case
        $record->encoding('UTF-8');
        my $stored_record = $record;
        if ($catalogued) {
            $stored_record = MARC::Record->new;
            $stored_record->leader( $record->leader );
            $stored_record->append_fields( grep { $_->tag ne $item_tag } $record->fields );
        }
        if ($use_array) {
            $record_document->{'marc_data_array'} = $self->_marc_to_array($stored_record);
            $record_document->{'marc_format'}     = 'ARRAY';
        } else {
            my @warnings;
            {
                # Temporarily intercept all warn signals (MARC::Record carps when record length > 99999)
                local $SIG{__WARN__} = sub {
                    push @warnings, $_[0];
                };
                my $usmarc_record = $stored_record->as_usmarc();

                #NOTE: Try to round-trip the record to prove it will work for retrieval after searching
                my $decoded_usmarc_record;
                eval { $decoded_usmarc_record = MARC::Record->new_from_usmarc($usmarc_record); };
                if ( $@ || $decoded_usmarc_record->warnings() ) {

                    #NOTE: We override the warnings since they're many and misleading
                    @warnings = (
                        "Warnings encountered while roundtripping a MARC record to/from USMARC. Failing over to MARCXML.",
                    );
                }

                my $marc_data = encode_base64( encode( 'UTF-8', $usmarc_record ) );
                $record_document->{'marc_data'} = $marc_data;
            }
            if (@warnings) {

                # Suppress warnings if record length exceeded
                unless ( substr( $stored_record->leader(), 0, 5 ) eq '99999' ) {
                    foreach my $warning (@warnings) {
                        carp $warning;
                    }
                }
                $record_document->{'marc_data'}   = $stored_record->as_xml_record($marcflavour);
                $record_document->{'marc_format'} = 'MARCXML';
            } else {
                $record_document->{'marc_format'} = 'base64ISO2709';
            }
        }

        if (   $self->index eq $AUTHORITIES_INDEX
            && exists $record_document->{'subject-heading-thesaurus'}
            && scalar @{ $record_document->{'subject-heading-thesaurus'} } > 1 )
        {
            # We should really only have two thesauri defined in the case where 008/_11 = 'z' and 040$f is defined
            # In that case, we should drop the z
            @{ $record_document->{'subject-heading-thesaurus'} } =
                map { $_ eq 'z' ? () : $_ } @{ $record_document->{'subject-heading-thesaurus'} };
        }

        # Check if there is at least one available item, and attach the nested
        # item documents (Bug XXXXX) built up front for this batch.
        if ($biblionumber_field) {
            my $avail_items = Koha::Items->search(
                {
                    biblionumber => $biblionumber,
                    onloan       => undef,
                    itemlost     => 0,
                }
            )->count;

            $record_document->{available} = $avail_items ? \1 : \0;
            $record_document->{items}     = $item_documents->{$biblionumber} // [];

            # Record-level item count (Bug XXXXX). Structural (patron
            # independent): lets a query tell "record with no items" apart
            # from "record whose items are all filtered out".
            $record_document->{items_count} = scalar @{ $record_document->{items} };

            $record_document->{items_schema_version} = $ITEMS_SCHEMA_VERSION if $catalogued;
        }

        Koha::Plugins->call(
            'elasticsearch_to_document',
            {
                index    => $self->index,
                record   => $record,
                document => $record_document,
            }
        );

        push @record_documents, $record_document;
    }
    return \@record_documents;
}

=head2 _get_item_documents

    my $items_by_biblio = $self->_get_item_documents(\@biblionumbers);

Builds the C<items> nested objects (Bug XXXXX) for a batch of biblionumbers and
returns a hashref mapping each biblionumber to an arrayref of item documents,
sorted by C<itemnumber>. Every biblionumber of a record in the catalogue has an
entry, empty if the record has no items, so a missing entry means that the
record is not in the catalogue.

Each item document carries the item's MARC field in C<marc> (see
L</_item_field_to_marc>), built by C<Koha::Item-E<gt>as_marc_field> as when the
items are embedded in the record, with the framework resolved once per record.

Item-level state that does not live in the C<items> table (transit and hold
status) and the libraries' geolocation are resolved with grouped queries over
the whole batch, to avoid N+1 lookups inside the indexing loop.

Some fields are computed from settings that are not item data: the
C<OpacHiddenItems> system preference (C<hidden_in_opac_by_preferences>) and the
C<item_hidden_in_opac> and C<item_available_for_patron> plugin hooks
(C<hidden_in_opac_custom>, C<available_for_patron>). They are evaluated when a
record is indexed, and nothing reindexes the records when those settings change:
whoever changes them (the administrator changing the preference, the developer or
administrator of the plugin when it is installed, enabled, disabled or
reconfigured, or when the data its hooks depend on changes) is responsible for
reindexing the affected records, e.g. with
C<misc/search_tools/rebuild_elasticsearch.pl>.

=cut

sub _get_item_documents {
    my ( $self, $biblionumbers ) = @_;

    my %items_by_biblio;
    return \%items_by_biblio unless @{$biblionumbers};

    # The framework of each record, needed to build the item MARC fields. It
    # also tells which records are in the catalogue.
    my %frameworkcode_by_biblio =
        map { $_->biblionumber => $_->frameworkcode }
        Koha::Biblios->search( { biblionumber => { -in => $biblionumbers } } )->as_list;
    $items_by_biblio{$_} = [] for keys %frameworkcode_by_biblio;

    my @items = Koha::Items->search(
        { biblionumber => { -in  => $biblionumbers } },
        { order_by     => { -asc => 'itemnumber' } }
    )->as_list;
    my @itemnumbers = map { $_->itemnumber } @items;
    return \%items_by_biblio unless @items;

    # in_transit: a transfer that has been sent but neither arrived nor
    # cancelled (mirrors Koha::Item::Transfer->in_transit).
    my %intransit;
    my $transfers = Koha::Item::Transfers->search(
        {
            itemnumber    => { -in  => \@itemnumbers },
            datesent      => { '!=' => undef },
            datearrived   => undef,
            datecancelled => undef,
        }
    );
    $intransit{ $_->itemnumber } = 1 for $transfers->as_list;

    # onrequest: any active (not cancelled, not suspended) hold on the item.
    # onhold: such a hold that is also waiting ('W') or in transit ('T').
    # blocking_hold: such a hold that is found ('W'/'T'/'P'), i.e. it makes the
    # item unreachable to a patron (feeds available_for_patron, Bug XXXXX).
    my ( %onhold, %onrequest, %blocking_hold );
    my $holds = Koha::Holds->search(
        {
            itemnumber       => { -in => \@itemnumbers },
            cancellationdate => undef,
            suspend          => 0,
        }
    );
    for my $hold ( $holds->as_list ) {
        my $itemnumber = $hold->itemnumber;
        $onrequest{$itemnumber} = 1;
        my $found = $hold->found;
        $onhold{$itemnumber}        = 1 if defined $found && ( $found eq 'W' || $found eq 'T' );
        $blocking_hold{$itemnumber} = 1 if $hold->is_found;    # W/T/P (canonical Koha method)
    }

    # branches is a small table: load branchcode => geolocation once and resolve
    # in memory rather than querying per item.
    my %geolocation_by_branch =
        map { $_->branchcode => $_->geolocation }
        grep { defined $_->geolocation && $_->geolocation ne '' } Koha::Libraries->search->as_list;

    # OpacHiddenItems rules, evaluated once for the whole batch.
    my $hidden_rules = C4::Context->yaml_preference('OpacHiddenItems') // {};

    # The plugins implementing the item hooks, resolved once for the whole
    # batch: looking them up for every item was most of the cost of building
    # the item documents.
    my ( $hidden_in_opac_plugins, $available_for_patron_plugins ) =
        $self->_item_hook_plugins( 'item_hidden_in_opac', 'item_available_for_patron' );

    # Index the effective item type (Koha::Item->effective_itemtype): the item
    # type of the record unless item-level_itypes is on and the item has its
    # own. The record item types are loaded once for the whole batch.
    my $item_level_itypes = C4::Context->preference('item-level_itypes');
    my %itemtype_by_biblioitem =
        map { $_->biblioitemnumber => $_->itemtype }
        Koha::Biblioitems->search( { biblionumber => { -in => $biblionumbers } } )->as_list;

    for my $item (@items) {
        my $itemnumber = $item->itemnumber;
        my $document   = {
            itemnumber    => $itemnumber + 0,
            homebranch    => $item->homebranch,
            holdingbranch => $item->holdingbranch,
            itype         => ( $item_level_itypes && $item->itype )
            ? $item->itype
            : $itemtype_by_biblioitem{ $item->biblioitemnumber },
            location             => $item->location,
            permanent_location   => $item->permanent_location,
            ccode                => $item->ccode,
            callnumber           => $item->itemcallnumber,
            cn_sort              => $item->cn_sort,
            barcode              => $item->barcode,
            enumchron            => $item->enumchron,
            restricted           => $item->restricted,
            notforloan           => $item->notforloan,
            onloan               => $item->onloan,
            damaged              => $item->damaged,
            lost                 => $item->itemlost,
            withdrawn            => $item->withdrawn,
            intransit            => $intransit{$itemnumber}                ? \1 : \0,
            onhold               => $onhold{$itemnumber}                   ? \1 : \0,
            onrequest            => $onrequest{$itemnumber}                ? \1 : \0,
            available            => ( !$item->onloan && !$item->itemlost ) ? \1 : \0,
            available_for_patron => $self->_item_available_for_patron(
                $item, $intransit{$itemnumber}, $blocking_hold{$itemnumber},
                $available_for_patron_plugins
            ) ? \1 : \0,
            hidden_in_opac_custom => $self->_item_hidden_in_opac_custom( $item, $hidden_in_opac_plugins ) ? \1 : \0,
            hidden_in_opac_by_preferences => $item->hidden_in_opac( { rules => $hidden_rules, skip_lost_check => 1 } )
            ? \1
            : \0,
        };

        # date_of_acquisition (search field) lives on items.dateaccessioned. The
        # column is a DATE (YYYY-MM-DD), already ES-parseable; omit the subfield
        # when empty so the `date` mapping does not reject a blank value.
        my $dateaccessioned = $item->dateaccessioned;
        $document->{dateaccessioned} = $dateaccessioned
            if defined $dateaccessioned && $dateaccessioned ne '';

        # geo_point accepts the native "lat,lon" string. Omit the subfield when
        # the library has no geolocation so ES does not reject an empty value.
        my $home_geolocation    = $geolocation_by_branch{ $item->homebranch };
        my $holding_geolocation = $geolocation_by_branch{ $item->holdingbranch };
        $document->{home_geolocation}    = $home_geolocation    if defined $home_geolocation;
        $document->{holding_geolocation} = $holding_geolocation if defined $holding_geolocation;

        # The item's MARC field, built as when the items are embedded in the
        # record (Koha::Filter::MARC::EmbedItems), so that the record rebuilt
        # from the index is the same.
        my $marc_field = $item->as_marc_field( { frameworkcode => $frameworkcode_by_biblio{ $item->biblionumber } } );
        $document->{marc} = $self->_item_field_to_marc($marc_field) if $marc_field;

        push @{ $items_by_biblio{ $item->biblionumber } }, $document;
    }

    return \%items_by_biblio;
}

=head2 _item_field_to_marc

    my $marc = $self->_item_field_to_marc($field);

Converts an item C<MARC::Field> into the string stored in C<items.marc>
(Bug XXXXX): the field data as in ISO2709, without the field terminator. That is,
the two indicators followed by every subfield, each one made of the subfield
delimiter (C<0x1F>), the code and the value:

    "  \x1faCPL\x1fbCPL\x1fp39000001"

The tag is not stored: it is the item tag of the MARC flavour. A single string
per item is smaller than a structure, and much faster to parse when a search
result is decoded.

A value cannot contain the subfield delimiter in a valid MARC record, but an item
column could. It would split the subfield when the field is read back, so it is
removed, with a warning.

=cut

sub _item_field_to_marc {
    my ( $self, $field ) = @_;

    my $marc = $field->indicator(1) . $field->indicator(2);
    for my $subfield ( $field->subfields ) {
        my ( $code, $value ) = @{$subfield};
        if ( $value =~ tr/\x1f//d ) {
            carp sprintf(
                'Removed the subfield delimiter (0x1F) from the value of subfield %s of item field %s',
                $code, $field->tag
            );
        }
        $marc .= "\x1f$code$value";
    }

    return $marc;
}

=head2 _item_marc_to_field

    my $field = $self->_item_marc_to_field( $tag, $marc );

Converts the C<items.marc> string of an item back into a C<MARC::Field> with the
given tag. The reverse of L</_item_field_to_marc>.

=cut

sub _item_marc_to_field {
    my ( $self, $tag, $marc ) = @_;

    my ( $indicators, @subfields ) = split /\x1f/, $marc;

    return MARC::Field->new(
        $tag,
        substr( $indicators, 0, 1 ),
        substr( $indicators, 1, 1 ),
        map { ( substr( $_, 0, 1 ), substr( $_, 1 ) ) } @subfields
    );
}

=head2 _append_item_fields

    $self->_append_item_fields( $record, $item_documents );

Appends to C<$record> the item fields stored in the C<marc> subfield of the
given item documents (Bug XXXXX), in C<itemnumber> order, which is the order in
which they are embedded in the record. Item documents without C<marc>, such as
the ones indexed before it existed, are skipped.

=cut

sub _append_item_fields {
    my ( $self, $record, $item_documents ) = @_;

    my @marcs =
        map  { $_->{marc} }
        sort { $a->{itemnumber} <=> $b->{itemnumber} }
        grep { $_->{marc} } @{ $item_documents // [] };
    return unless @marcs;

    my ($item_tag) = C4::Biblio::GetMarcFromKohaField('items.itemnumber');
    $record->append_fields( map { $self->_item_marc_to_field( $item_tag, $_ ) } @marcs );

    return;
}

=head2 _item_hook_plugins

    my ( $hidden_in_opac_plugins, $available_for_patron_plugins ) =
        $self->_item_hook_plugins( 'item_hidden_in_opac', 'item_available_for_patron' );

Returns, for each hook name passed, an arrayref with the enabled plugins that
implement it, in the order of C<Koha::Plugins-E<gt>get_enabled_plugins>. The
enabled plugins are looked up once, whatever the number of hooks. The arrayrefs
are empty when plugins are disabled.

=cut

sub _item_hook_plugins {
    my ( $self, @hooks ) = @_;

    my @plugins =
        C4::Context->config('enable_plugins') ? Koha::Plugins->get_enabled_plugins( { verbose => 0 } ) : ();

    return map {
        my $hook = $_;
        [ grep { $_->can($hook) } @plugins ]
    } @hooks;
}

=head2 _item_hidden_in_opac_custom

    my $bool = $self->_item_hidden_in_opac_custom( $item, $plugins );

Custom OPAC item-hiding rules (Bug XXXXX). Feeds the C<item.hidden_in_opac_custom>
field. Delegates to the C<item_hidden_in_opac> plugin hook, passing the item, and
is B<restrictive>: it stops and hides the item as soon as the first plugin returns
a true value, without calling the remaining plugins.

C<$plugins> is an optional arrayref with the plugins implementing the hook, as
returned by L</_item_hook_plugins>, so that a batch resolves them only once (see
L</_get_item_documents>). When it is not passed, they are looked up here.

Returns 0 (not hidden) when no plugin vetoes the item, when no plugin implements
the hook, or when plugins are disabled. This hiding is unconditional (it is not
lifted by C<OpacHiddenItemsExceptions>).

A plugin that dies fails closed: the item is hidden, without calling the
remaining plugins, and the error is logged (see L</_log_item_hook_error>).

The result is stored in the index when the record is indexed: a plugin whose
answer changes (new rules, configuration, data) must have the affected records
reindexed (see L</_get_item_documents>).

=cut

sub _item_hidden_in_opac_custom {
    my ( $self, $item, $plugins ) = @_;

    ($plugins) = $self->_item_hook_plugins('item_hidden_in_opac') unless $plugins;

    for my $plugin ( @{$plugins} ) {
        my $hidden;
        unless ( eval { $hidden = $plugin->item_hidden_in_opac( { item => $item } ); 1 } ) {
            $self->_log_item_hook_error( $plugin, 'item_hidden_in_opac', $@, 'the item is hidden in the OPAC' );
            return 1;
        }
        return 1 if $hidden;
    }

    return 0;
}

=head2 _item_available_for_patron

    my $bool = $self->_item_available_for_patron( $item, $intransit, $blocked_by_hold, $plugins );

Patron-facing availability (Bug XXXXX). Feeds the C<item.available_for_patron>
field: whether a patron could request the loan or consultation of this item. This
is B<distinct> from C<item.available> (the community, staff-facing flag), which is
left untouched.

Delegates to the C<item_available_for_patron> plugin hook with B<three-state>
semantics and priority C<< false > true > default >> (which differs from the
additive veto of C<_item_hidden_in_opac_custom>). The hook receives the item plus
the batch-computed C<intransit> and C<blocked_by_hold> flags, so a plugin can weigh
the same inputs as the default conditions without querying C<branchtransfers> and
C<reserves> again:

=over 4

=item * the first plugin returning a defined B<false> makes the item unavailable
and short-circuits (false is final);

=item * if no plugin returns false and at least one returns B<true>, the item is
available;

=item * if there are no plugins, plugins are disabled, or every plugin abstains
(returns C<undef>), the default conditions below apply.

=back

A plugin that dies fails closed: the item is not available, without calling the
remaining plugins, and the error is logged (see L</_log_item_hook_error>).

Default conditions: the item is B<not> available if any of these holds:
C<itemlost> is non-zero, C<withdrawn> is truthy, C<damaged> is truthy, the item is
C<$intransit>, or it is C<$blocked_by_hold> (an active hold found in 'W'/'T'/'P').

C<onloan>, C<restricted> and C<notforloan> do B<not> affect the value. C<onloan> is
excluded on purpose: an item that is checked out can still be reserved by a patron,
so a loan does not make it unrequestable (C4::Reserves::IsAvailableForItemLevelRequest
never excludes on-loan items). This is what makes the field diverge from the
community C<available> flag, which does treat C<onloan> as unavailable.

C<$intransit> and C<$blocked_by_hold> are the batch-computed booleans for this item
(see L</_get_item_documents>). C<$plugins> is an optional arrayref with the plugins
implementing the hook, as returned by L</_item_hook_plugins>, so that a batch
resolves them only once. When it is not passed, they are looked up here.

The result is stored in the index when the record is indexed: a plugin whose
answer changes (new rules, configuration, data) must have the affected records
reindexed (see L</_get_item_documents>).

=cut

sub _item_available_for_patron {
    my ( $self, $item, $intransit, $blocked_by_hold, $plugins ) = @_;

    ($plugins) = $self->_item_hook_plugins('item_available_for_patron') unless $plugins;

    my $saw_true = 0;
    for my $plugin ( @{$plugins} ) {
        my $value;
        my $ok = eval {
            $value = $plugin->item_available_for_patron(
                {
                    item            => $item,
                    intransit       => $intransit,
                    blocked_by_hold => $blocked_by_hold,
                }
            );
            1;
        };
        unless ($ok) {
            $self->_log_item_hook_error(
                $plugin, 'item_available_for_patron', $@,
                'the item is not available for patrons'
            );
            return 0;
        }
        next     unless defined $value;    # abstention
        return 0 unless $value;            # defined false: not available, short-circuit
        $saw_true = 1;
    }
    return 1 if $saw_true;                 # some true, no false: available

    # Default conditions (no plugin opinion): not available if any of these holds.
    # `onloan` is deliberately NOT a condition: a checked-out item can still be
    # placed on hold by a patron (see C4::Reserves::IsAvailableForItemLevelRequest,
    # which never excludes on-loan items).
    return 0 if $item->itemlost;     # non-zero
    return 0 if $item->withdrawn;    # truthy
    return 0 if $item->damaged;      # truthy
    return 0 if $intransit;          # derived from branchtransfers
    return 0 if $blocked_by_hold;    # active hold found IN ('W','T','P')

    return 1;
}

=head2 _log_item_hook_error

    $self->_log_item_hook_error( $plugin, $hook, $error, $outcome );

Logs, at error level, that C<$plugin> died in the item hook C<$hook> with
C<$error>, and the C<$outcome> applied to the item instead (Bug XXXXX). The
plugin name is read within an C<eval>, so that a broken plugin cannot make the
logging die too; the plugin class is used when it cannot be read.

=cut

sub _log_item_hook_error {
    my ( $self, $plugin, $hook, $error, $outcome ) = @_;

    my $name = eval { $plugin->get_metadata->{name} } || ref $plugin;
    chomp $error;
    Koha::Logger->get->error( sprintf( "Plugin error (%s) in %s, %s: %s", $name, $hook, $outcome, $error ) );

    return;
}

=head2 _process_data_field_rules($rules, $field, $record_document, $altscript, $exclude_target_fields_regexp)

Process mapping rules for a single MARC::Field data field.

=over 4

=item C<$rules>

Data field mapping rules to be applied.

=item C<$field>

The source Marc::Field data field.

=item C<$record_document>

The target elasticsearch document.

=item C<$altscript>

A boolean value indicating whether an alternate script presentation is being
processed.

=item C<$exclude_target_fields_regexp>

An optional regexp for excluding target fields in mappings.

=back

=cut

sub _process_data_field_rules {
    my ( $self, $rules, $field, $record_document, $altscript, $exclude_target_fields_regexp ) = @_;
    if ($rules) {
        my $subfields_mappings = $rules->{subfields};
        my $wildcard_mappings  = $subfields_mappings->{'*'};
        foreach my $subfield ( $field->subfields() ) {
            my ( $code, $data ) = @{$subfield};
            my @mappings;
            push @mappings, @{ $subfields_mappings->{$code} } if $subfields_mappings->{$code};
            push @mappings, @{$wildcard_mappings}             if $wildcard_mappings;
            if (@mappings) {
                if ($exclude_target_fields_regexp) {
                    @mappings = grep { $_->[0] !~ $exclude_target_fields_regexp } @mappings;
                }
                $self->_process_mappings(
                    \@mappings,
                    $data,
                    $record_document,
                    {
                        altscript   => $altscript,
                        data_source => 'subfield',
                        code        => $code,
                        field       => $field
                    }
                );
            }
        }

        my $subfields_join_mappings = $rules->{subfields_join};
        if ($subfields_join_mappings) {
            foreach my $subfields_group ( keys %{$subfields_join_mappings} ) {

                # copy field to preserve for alt scripts
                my $data_field = $field->clone;

                #remove empty subfields, otherwise they are printed as a space
                $data_field->delete_subfield( match => qr/^$/ );

                #get values for subfields as a combined string, preserving record order
                my $data = $data_field->as_string($subfields_group);
                if ($data) {
                    my @mappings = @{ $subfields_join_mappings->{$subfields_group} };
                    if ($exclude_target_fields_regexp) {
                        @mappings = grep { $_->[0] !~ /$exclude_target_fields_regexp/ } @mappings;
                    }
                    $self->_process_mappings(
                        \@mappings,
                        $data,
                        $record_document,
                        {
                            altscript   => $altscript,
                            data_source => 'subfields_group',
                            codes       => $subfields_group,
                            field       => $field
                        }
                    );
                }
            }
        }
    }
}

=head2 _marc_to_array($record)

    my @fields = _marc_to_array($record)

Convert a MARC::Record to an array modeled after MARC-in-JSON
(see https://github.com/marc4j/marc4j/wiki/MARC-in-JSON-Description)

=over 4

=item C<$record>

A MARC::Record object

=back

=cut

sub _marc_to_array {
    my ( $self, $record ) = @_;

    my $data = {
        leader => $record->leader(),
        fields => []
    };
    for my $field ( $record->fields() ) {
        my $tag = $field->tag();
        if ( $field->is_control_field() ) {
            push @{ $data->{fields} }, { $tag => $field->data() };
        } else {
            my $subfields = ();
            foreach my $subfield ( $field->subfields() ) {
                my ( $code, $contents ) = @{$subfield};
                push @{$subfields}, { $code => $contents };
            }
            push @{ $data->{fields} }, {
                $tag => {
                    ind1      => $field->indicator(1),
                    ind2      => $field->indicator(2),
                    subfields => $subfields
                }
            };
        }
    }
    return $data;
}

=head2 _array_to_marc($data)

    my $record = _array_to_marc($data)

Convert an array modeled after MARC-in-JSON to a MARC::Record

=over 4

=item C<$data>

An array modeled after MARC-in-JSON
(see https://github.com/marc4j/marc4j/wiki/MARC-in-JSON-Description)

=back

=cut

sub _array_to_marc {
    my ( $self, $data ) = @_;

    my $record = MARC::Record->new();

    $record->leader( $data->{leader} );
    for my $field ( @{ $data->{fields} } ) {
        my $tag = ( keys %{$field} )[0];
        $field = $field->{$tag};
        my $marc_field;
        if ( ref($field) eq 'HASH' ) {
            my @subfields;
            foreach my $subfield ( @{ $field->{subfields} } ) {
                my $code = ( keys %{$subfield} )[0];
                push @subfields, $code;
                push @subfields, $subfield->{$code};
            }
            $marc_field = MARC::Field->new( $tag, $field->{ind1}, $field->{ind2}, @subfields );
        } else {
            $marc_field = MARC::Field->new( $tag, $field );
        }
        $record->append_fields($marc_field);
    }

    return $record;
}

=head2 _field_mappings($facet, $suggestible, $sort, $search, $filter, $target_name, $target_type, $range)

    my @mappings = _field_mappings( $facet, $suggestible, $sort, $search, $filter, $target_name, $target_type, $range )

Get mappings, an internal data structure later used by
L<_process_mappings($mappings, $data, $record_document, $meta)> to process MARC target
data for a MARC mapping.

The returned C<$mappings> is not to to be confused with mappings provided by
C<_foreach_mapping>, rather this sub accepts properties from a mapping as
provided by C<_foreach_mapping> and expands it to this internal data structure.
In the caller context (C<_get_marc_mapping_rules>) the returned C<@mappings>
is then applied to each MARC target (leader, control field data, subfield or
joined subfields) and integrated into the mapping rules data structure used in
C<marc_records_to_documents> to transform MARC records into Elasticsearch
documents.

=over 4

=item C<$facet>

Boolean indicating whether to create a facet field for this mapping.

=item C<$suggestible>

Boolean indicating whether to create a suggestion field for this mapping.

=item C<$sort>

Boolean indicating whether to create a sort field for this mapping.

=item C<$search>

Boolean indicating whether to create a search field for this mapping.

=item C<$target_name>

Elasticsearch document target field name.

=item C<$target_type>

Elasticsearch document target field type.

=item C<$range>

An optional range as a string in the format "<START>-<END>" or "<START>",
where "<START>" and "<END>" are integers specifying a range that will be used
for extracting a substring from MARC data as Elasticsearch field target value.

The first character position is "0", and the range is inclusive,
so "0-2" means the first three characters of MARC data.

If only "<START>" is provided only one character at position "<START>" will
be extracted.

=back

=cut

sub _field_mappings {
    my ( $_self, $facet, $suggestible, $sort, $search, $filter, $target_name, $target_type, $range ) = @_;
    my %mapping_defaults = ();
    my @mappings;

    my $substr_args = undef;
    if ( defined $range ) {

        # TODO: use value_callback instead?
        my ( $start, $end ) = map( int, split /-/, $range, 2 );
        $substr_args = [$start];
        push @{$substr_args}, ( defined $end ? $end - $start + 1 : 1 );
    }
    my $default_options = {};
    if ($substr_args) {
        $default_options->{substr} = $substr_args;
    }

    # TODO: Should probably have per type value callback/hook
    # but hard code for now
    if ( $target_type eq 'boolean' ) {
        $default_options->{value_callbacks} //= [];
        push @{ $default_options->{value_callbacks} }, sub {
            my ($value) = @_;

            # Trim whitespace at both ends
            $value =~ s/^\s+|\s+$//g;
            return $value ? 'true' : 'false';
        };
    } elsif ( $target_type eq 'year' ) {
        $default_options->{value_callbacks} //= [];

        # Only accept years containing digits and "u"
        push @{ $default_options->{value_callbacks} }, sub {
            my ($value) = @_;

            # Replace "u" with "0" for sorting
            return map { s/[u\s]/0/gr } ( $value =~ /[0-9u\s]{4}/g );
        };
    }

    if ( defined $filter && $filter eq 'punctuation' ) {
        $default_options->{value_callbacks} //= [];
        push @{ $default_options->{value_callbacks} }, sub {
            my ($value) = @_;

            # Trim punctuation marks from field
            $value =~
                s/[\x00-\x1F,\x21-\x2F,\x3A-\x40,\x5B-\x60,\x7B-\x89,\x8B,\x8D,\x8F,\x90-\x99,\x9B,\x9D,\xA0-\xBF,\xD7,\xF7]//g;
            return $value;
        };
    }

    if ($search) {
        my $mapping = [ $target_name, $default_options ];
        push @mappings, $mapping;
    }

    my @suffixes = ();
    push @suffixes, 'facet'      if $facet;
    push @suffixes, 'suggestion' if $suggestible;
    push @suffixes, 'sort'       if !defined $sort || $sort;

    foreach my $suffix (@suffixes) {
        my $mapping = ["${target_name}__$suffix"];

        # TODO: Hack, fix later in less hideous manner
        if ( $suffix eq 'suggestion' ) {
            push @{$mapping}, { %{$default_options}, property => 'input' };
        } else {

            # Important! Make shallow clone, or we end up with the same hashref
            # shared by all mappings
            push @{$mapping}, { %{$default_options} };
        }
        push @mappings, $mapping;
    }
    return @mappings;
}

=head2 _get_marc_mapping_rules

    my $mapping_rules = $self->_get_marc_mapping_rules()

Generates rules from mappings stored in database for MARC records to Elasticsearch JSON document conversion.

Since field retrieval is slow in C<MARC::Records> (all fields are itereted through for
each call to C<MARC::Record>->field) we create an optimized structure of mapping
rules keyed by MARC field tags holding all the mapping rules for that particular tag.

We can then iterate through all MARC fields for each record and apply all relevant
rules once per fields instead of retrieving fields multiple times for each mapping rule
which is terribly slow.

=cut

# TODO: This structure can be used for processing multiple MARC::Records so is currently
# rebuilt for each batch. Since it is cacheable it could also be stored in an in
# memory cache which it is currently not. The performance gain of caching
# would probably be marginal, but to do this could be a further improvement.

sub _get_marc_mapping_rules {
    my ($self)            = @_;
    my $marcflavour       = lc C4::Context->preference('marcflavour');
    my $field_spec_regexp = qr/^([0-9]{3})([()0-9a-zA-Z]+)?(?:_\/(\d+(?:-\d+)?))?$/;
    my $leader_regexp     = qr/^leader(?:_\/(\d+(?:-\d+)?))?$/;
    my $rules             = {
        'leader'         => [],
        'control_fields' => {},
        'data_fields'    => {},
        'sum'            => [],
        'isbn'           => [],
        'defaults'       => {}
    };

    $self->_foreach_mapping(
        sub {
            my ( $name, $type, $facet, $suggestible, $sort, $search, $filter, $marc_type, $marc_field ) = @_;
            return if $marc_type ne $marcflavour;

            if ( $type eq 'sum' ) {
                push @{ $rules->{sum} }, $name;
                push @{ $rules->{sum} }, $name . "__sort" if $sort;
            } elsif ( $type eq 'isbn' ) {
                push @{ $rules->{isbn} }, $name;
            } elsif ( $type eq 'geo_point' ) {
                push @{ $rules->{geo_point} }, $name;
            } elsif ( $type eq 'boolean' ) {

                # boolean gets special handling, if value doesn't exist for a field,
                # it is set to false
                $rules->{defaults}->{$name} = 'false';
            }

            if ( $marc_field =~ $field_spec_regexp ) {
                my $field_tag = $1;

                my @subfields;
                my @subfield_groups;

                # Parse and separate subfields form subfield groups
                if ( defined $2 ) {
                    my $subfield_group = '';
                    my $open_group     = 0;

                    foreach my $token ( split //, $2 ) {
                        if ( $token eq "(" ) {
                            if ($open_group) {
                                Koha::Exceptions::Elasticsearch::MARCFieldExprParseError->throw(
                                    "Unmatched opening parenthesis for $marc_field");
                            } else {
                                $open_group = 1;
                            }
                        } elsif ( $token eq ")" ) {
                            if ($open_group) {
                                if ($subfield_group) {
                                    push @subfield_groups, $subfield_group;
                                    $subfield_group = '';
                                }
                                $open_group = 0;
                            } else {
                                Koha::Exceptions::Elasticsearch::MARCFieldExprParseError->throw(
                                    "Unmatched closing parenthesis for $marc_field");
                            }
                        } elsif ($open_group) {
                            $subfield_group .= $token;
                        } else {
                            push @subfields, $token;
                        }
                    }
                } else {
                    push @subfields, '*';
                }

                my $range = defined $3 ? $3 : undef;
                my @mappings =
                    $self->_field_mappings( $facet, $suggestible, $sort, $search, $filter, $name, $type, $range );
                if ( $field_tag < 10 ) {
                    $rules->{control_fields}->{$field_tag} //= [];
                    push @{ $rules->{control_fields}->{$field_tag} }, @{ clone( \@mappings ) };
                } else {
                    $rules->{data_fields}->{$field_tag} //= {};
                    foreach my $subfield (@subfields) {
                        $rules->{data_fields}->{$field_tag}->{subfields}->{$subfield} //= [];
                        push @{ $rules->{data_fields}->{$field_tag}->{subfields}->{$subfield} },
                            @{ clone( \@mappings ) };
                    }
                    foreach my $subfield_group (@subfield_groups) {
                        $rules->{data_fields}->{$field_tag}->{subfields_join}->{$subfield_group} //= [];
                        push @{ $rules->{data_fields}->{$field_tag}->{subfields_join}->{$subfield_group} },
                            @{ clone( \@mappings ) };
                    }
                }
            } elsif ( $marc_field =~ $leader_regexp ) {
                my $range = defined $1 ? $1 : undef;
                my @mappings =
                    $self->_field_mappings( $facet, $suggestible, $sort, $search, $filter, $name, $type, $range );
                push @{ $rules->{leader} }, @{ clone( \@mappings ) };
            } else {
                Koha::Exceptions::Elasticsearch::MARCFieldExprParseError->throw(
                    "Invalid MARC field expression: $marc_field");
            }
        }
    );

    # Marc-flavour specific rule tweaks, could/should also provide hook for this
    if ( $marcflavour eq 'marc21' ) {

        # Nonfiling characters processing for sort fields
        my %title_fields;
        if ( $self->index eq $Koha::SearchEngine::BIBLIOS_INDEX ) {

            # Format is: nonfiling characters indicator => field names list
            %title_fields = (
                1 => [ 130, 630, 730, 740 ],
                2 => [ 222, 240, 242, 243, 245, 440, 830 ]
            );
        } elsif ( $self->index eq $Koha::SearchEngine::AUTHORITIES_INDEX ) {
            %title_fields = (
                1 => [730],
                2 => [ 130, 430, 530 ]
            );
        }
        foreach my $indicator ( keys %title_fields ) {
            foreach my $field_tag ( @{ $title_fields{$indicator} } ) {
                my $mappings = $rules->{data_fields}->{$field_tag}->{subfields}->{a} // [];
                foreach my $mapping ( @{$mappings} ) {

                    # Mark this as to be processed for nonfiling characters indicator
                    # later on in _process_mappings
                    $mapping->[1]->{nonfiling_characters_indicator} = $indicator;
                }
            }
        }
    }

    if ( $self->index eq 'authorities' ) {
        push @{ $rules->{control_fields}->{'008'} }, [ 'subject-heading-thesaurus', { 'substr' => [ 11, 1 ] } ];
        push @{ $rules->{data_fields}->{'040'}->{subfields}->{f} }, [ 'subject-heading-thesaurus', {} ];
    }

    return $rules;
}

=head2 _foreach_mapping

    $self->_foreach_mapping(
        sub {
            my ( $name, $type, $facet, $suggestible, $sort, $search, $filter, $marc_type,
                $marc_field )
              = @_;
            return unless $marc_type eq 'marc21';
            print "Data comes from: " . $marc_field . "\n";
        }
    );

This allows you to apply a function to each entry in the elasticsearch mappings
table, in order to build the mappings for whatever is needed.

In the provided function, the files are:

=over 4

=item C<$name>

The field name for elasticsearch (corresponds to the 'mapping' column in the
database.

=item C<$type>

The type for this value, e.g. 'string'.

=item C<$facet>

True if this value should be facetised. This only really makes sense if the
field is understood by the facet processing code anyway.

=item C<$sort>

True if this is a field that a) needs special sort handling, and b) if it
should be sorted on. False if a) but not b). Undef if not a). This allows,
for example, author to be sorted on but not everything marked with "author"
to be included in that sort.

=item C<$search>

True if this value should be searchable.

=item C<$filter>

Contains a string that represents a filter defined in the indexing code. Currently supports
the option 'punctuation'

=item C<$marc_type>

A string that indicates the MARC type that this mapping is for, e.g. 'marc21',
'unimarc'.

=item C<$marc_field>

A string that describes the MARC field that contains the data to extract.

=back

=cut

sub _foreach_mapping {
    my ( $self, $sub ) = @_;

    # TODO use a caching framework here
    my $search_fields = Koha::Database->schema->resultset('SearchField')->search(
        {
            'search_marc_map.index_name' => $self->index,
        },
        {
            join      => { search_marc_to_fields => 'search_marc_map' },
            '+select' => [
                'search_marc_to_fields.facet',
                'search_marc_to_fields.suggestible',
                'search_marc_to_fields.sort',
                'search_marc_to_fields.search',
                'search_marc_to_fields.filter',
                'search_marc_map.marc_type',
                'search_marc_map.marc_field',
            ],
            '+as' => [
                'facet',
                'suggestible',
                'sort',
                'search',
                'filter',
                'marc_type',
                'marc_field',
            ],
        }
    );

    while ( my $search_field = $search_fields->next ) {
        $sub->(
            # Force lower case on indexed field names for case insensitive
            # field name searches
            lc( $search_field->name ),
            $search_field->type,
            $search_field->get_column('facet'),
            $search_field->get_column('suggestible'),
            $search_field->get_column('sort'),
            $search_field->get_column('search'),
            $search_field->get_column('filter'),
            $search_field->get_column('marc_type'),
            $search_field->get_column('marc_field'),
        );
    }
}

=head2 process_error

    die process_error($@);

This parses an Elasticsearch error message and produces a human-readable
result from it. This result is probably missing all the useful information
that you might want in diagnosing an issue, so the warning is also logged.

Note that currently the resulting message is not internationalised. This
will happen eventually by some method or other.

=cut

sub process_error {
    my ( $self, $msg ) = @_;

    warn $msg;    # simple logging

    # This is super-primitive
    return __("Unable to understand your search query, please rephrase and try again.\n")
        if $msg =~ /ParseException|parse_exception/;

    return __("Unable to perform your search. Please try again.\n");
}

=head2 _read_configuration

    my $conf = _read_configuration();

Reads the I<configuration file> and returns a hash structure with the
configuration information. It raises an exception if mandatory entries
are missing.

The hashref structure has the following form:

    {
        'nodes' => ['127.0.0.1:9200', 'anotherserver:9200'],
        'index_name' => 'koha_instance',
    }

This is configured by the following in the C<config> block in koha-conf.xml:

    <elasticsearch>
        <server>127.0.0.1:9200</server>
        <server>anotherserver:9200</server>
        <index_name>koha_instance</index_name>
    </elasticsearch>

=cut

sub _read_configuration {

    my $configuration;

    my $conf = C4::Context->config('elasticsearch');
    unless ( defined $conf ) {
        Koha::Exceptions::Config::MissingEntry->throw("Missing <elasticsearch> entry in koha-conf.xml");
    }

    unless ( exists $conf->{server} ) {
        Koha::Exceptions::Config::MissingEntry->throw("Missing <elasticsearch>/<server> entry in koha-conf.xml");
    }

    unless ( exists $conf->{index_name} ) {
        Koha::Exceptions::Config::MissingEntry->throw(
            "Missing <elasticsearch>/<index_name> entry in koha-conf.xml",
        );
    }

    while ( my ( $var, $val ) = each %$conf ) {
        if ( $var eq 'server' ) {
            if ( ref($val) eq 'ARRAY' ) {
                $configuration->{nodes} = $val;
            } else {
                $configuration->{nodes} = [$val];
            }
        } else {
            $configuration->{$var} = $val;
        }
    }

    $configuration->{cxn_pool} //= 'Static';

    return $configuration;
}

=head2 get_facet_fields

my @facet_fields = Koha::SearchEngine::Elasticsearch->get_facet_fields();

Returns the list of Koha::SearchFields marked to be faceted.

=cut

sub get_facet_fields {
    my ($self) = @_;

    return Koha::SearchFields->search( { facet_order => { '!=' => undef } }, { order_by => ['facet_order'] } )->as_list;
}

=head2 clear_search_fields_cache

Koha::SearchEngine::Elasticsearch->clear_search_fields_cache();

Clear cached values for ES search fields

=cut

sub clear_search_fields_cache {

    my $cache = Koha::Caches->get_instance();
    $cache->clear_from_cache('elasticsearch_search_fields_staff_client_biblios');
    $cache->clear_from_cache('elasticsearch_search_fields_opac_biblios');
    $cache->clear_from_cache('elasticsearch_search_fields_staff_client_authorities');
    $cache->clear_from_cache('elasticsearch_search_fields_opac_authorities');

}

1;

__END__

=head1 AUTHOR

=over 4

=item Chris Cormack C<< <chrisc@catalyst.net.nz> >>

=item Robin Sheat C<< <robin@catalyst.net.nz> >>

=item Jonathan Druart C<< <jonathan.druart@bugs.koha-community.org> >>

=back

=cut
