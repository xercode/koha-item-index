package Koha::BackgroundJob::UpdateBiblioItemsGeolocation;

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

use Modern::Perl;

use Try::Tiny;

use Koha::Database;
use Koha::Items;
use Koha::Exceptions;
use Koha::SearchEngine;
use Koha::SearchEngine::Indexer;

use base 'Koha::BackgroundJob';

=head1 NAME

Koha::BackgroundJob::UpdateBiblioItemsGeolocation - Reindex every biblio holding
items in a given library after its geolocation changed (Bug XXXXX).

This is a subclass of Koha::BackgroundJob.

The home/holding library geolocation is denormalized into the nested item
documents (C<items.home_geolocation> / C<items.holding_geolocation>). A change in
C<branches.geolocation> therefore invalidates the items of every biblio with an
item in that library, a fan-out that must never run synchronously inside the
administrator request. This job resolves the affected biblios and reindexes them
in batches.

=head1 API

=head2 Class methods

=head3 job_type

Define the job type of this job: I<update_biblio_items_geolocation>.

=cut

sub job_type {
    return 'update_biblio_items_geolocation';
}

=head3 process

Resolve every biblio holding an item whose home or holding branch is the changed
library and reindex them in batches.

=cut

sub process {
    my ( $self, $args ) = @_;

    $self->start;

    my $branchcode = $args->{branchcode};

    my @biblionumbers = Koha::Items->search(
        { -or     => [ { homebranch => $branchcode }, { holdingbranch => $branchcode } ] },
        { columns => 'biblionumber', distinct => 1 }
    )->get_column('biblionumber');

    my $report = {
        branchcode    => $branchcode,
        total_biblios => scalar @biblionumbers,
        total_success => 0,
    };

    my @messages;
    if (@biblionumbers) {
        try {
            my $indexer = Koha::SearchEngine::Indexer->new( { index => $Koha::SearchEngine::BIBLIOS_INDEX } );
            $indexer->index_records( \@biblionumbers, "specialUpdate", "biblioserver" );
            $report->{total_success} = scalar @biblionumbers;
            push @messages, { type => 'success', code => 'biblios_reindexed' };
        } catch {
            push @messages, { type => 'error', code => 'reindex_error', error => "$_" };
        };
    }

    $self->step;

    my $data = $self->decoded_data;
    $data->{messages} = \@messages;
    $data->{report}   = $report;

    $self->finish($data);
}

=head3 enqueue

Enqueue the new job. The mandatory I<branchcode> parameter is the library whose
geolocation changed.

=cut

sub enqueue {
    my ( $self, $args ) = @_;

    Koha::Exceptions::MissingParameter->throw("The 'branchcode' parameter is mandatory")
        unless exists $args->{branchcode};

    $self->SUPER::enqueue(
        {
            job_size => 1,
            job_args => { branchcode => $args->{branchcode} },
        }
    );
}

1;
