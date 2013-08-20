#include "utils.h"
#include "size-info.h"

/** block bits for all superblocks (content may change) */
uint * __constant__ block_bits_g;
/** allocation size id's (content may change); size id for each allocation takes
		1 byte, with size id "all set" meaning "no allocation" */
uint * __constant__ alloc_sizes_g;
/** number of block bit words per superblock */
__constant__ uint nsb_bit_words_g;
/** shift for number of words per superblock */
__constant__ uint nsb_bit_words_sh_g;
/** number of alloc sizes per superblock */
__constant__ uint nsb_alloc_words_g;

/** superblock descriptors */
__device__ superblock_t sbs_g[MAX_NSBS];
/** superblock's (non-distributed) counters */
__device__ uint sb_counters_g[MAX_NSBS];

/** the set of all unallocated slabs */
__device__ sbset_t unallocated_sbs_g;
/** the set of all free superblocks */
__device__ sbset_t free_sbs_g;
/** the set of "roomy" superblocks for the size */
__device__ sbset_t roomy_sbs_g[MAX_NSIZES];

/** head superblocks for each size */
__device__ uint head_sbs_g[NHEADS][MAX_NSIZES];
/** cached head SB's for each size */
__device__ volatile uint cached_sbs_g[NHEADS][MAX_NSIZES];
/** superblock operation locks per size */
__device__ uint head_locks_g[NHEADS][MAX_NSIZES];

/** gets block bits for superblock */
__device__ inline uint *sb_block_bits(uint sb) {
	// TODO: use a shift constant
	//return block_bits_g + sb * nsb_bit_words_g;
	return block_bits_g + (sb << nsb_bit_words_sh_g);
}  // sb_block_bits

/** gets the alloc sizes for the superblock */
__device__ inline uint *sb_alloc_sizes(uint sb) {
	// TODO: use a shift constant
	return alloc_sizes_g + sb * nsb_alloc_words_g;
}

/** sets allocation size for the allocation 
		@param alloc_words allocation data for this superblock
		@param ichunk the first allocated chunk
		@param nchunks the number of chunks allocated, max 15
		@param size_id id of the allocation size
 */
__device__ inline void sb_set_alloc_size
(uint *alloc_words, uint ichunk, uint	nchunks) {
	uint iword = ichunk / 4, ibyte = ichunk % 4, shift = ibyte * 8;
	uint mask = nchunks << shift;
	atomicOr(&alloc_words[iword], mask);
	//uint mask = (size_id << shift) | (~0 ^ (0xfu << shift));
	//atomicAnd(&alloc_words[iword], mask);
}  // sb_set_alloc_size

/** gets (and resets) allocation size for the allocation 
		@returns the number of chunks allocated for this allocation (max 15)
 */
__device__ inline uint sb_get_reset_alloc_size(uint *alloc_words, uint ichunk) {
	uint iword = ichunk / 4, ibyte = ichunk % 4, shift = ibyte * 8;
	uint mask = ~(0xf << shift);
	return (atomicAnd(&alloc_words[iword], mask) >> shift) & 0xfu;
	//uint mask = 0xfu << shift;
	//return (atomicOr(&alloc_words[iword], mask) >> shift) & 0xfu;
}  // sb_get_reset_alloc_size

/** tries to mark a slab as free 
		@param from_head whether there's a try to mark slab as free during detaching
		from head (this is very unlikely)
 */
__device__ inline void sb_try_mark_free
(uint sb, uint size_id, uint chunk_id, bool from_head) {
	// try marking slab as free
	uint old_counter = sb_counter_val(0, false, chunk_id, size_id);
	uint new_counter = sb_counter_val(0, false, SZ_NONE, SZ_NONE);
	if(atomicCAS(&sb_counters_g[sb], old_counter, new_counter) == old_counter) {
		// slab marked as free, remove it from roomy and add to free
		if(!from_head)
			sbset_remove_from(roomy_sbs_g[size_id], sb);
		sbs_g[sb].size_id = SZ_NONE;
		sbs_g[sb].chunk_sz = 0;
		sbset_add_to(free_sbs_g, sb);
	} else if(from_head) {
		// add it to non-free
		sbset_add_to(roomy_sbs_g[size_id], sb);
	}
}  // sb_try_mark_free

/** increment the non-distributed counter of the superblock 
		size_id is just ignored, allocation size is expressed in chunks
		@returns a mask which indicates
		bit 0 = whether allocation succeeded (0 = allocation failed due to block
		being freed)
		bit 1 = whether size_id threshold have been crossed 
 */
__device__ __forceinline__ uint sb_ctr_inc
(uint size_id, uint chunk_id, uint sb_id, uint nchunks) {
	uint return_mask = 1;
	bool want_inc = true;
	uint mask, old_counter, lid = threadIdx.x % WARP_SZ;
	while(mask = __ballot(want_inc)) {
		uint leader_lid = warp_leader(mask), leader_sb_id = sb_id;
		leader_sb_id = __shfl((int)leader_sb_id, leader_lid);
		// allocation size is same for all superblocks
		//uint change = alloc_sz * __popc(__ballot(sb_id == leader_sb_id));
		uint change = nchunks * __popc(__ballot(sb_id == leader_sb_id));
		if(lid == leader_lid)
			old_counter = sb_counter_inc(&sb_counters_g[sb_id], change);
		if(leader_sb_id == sb_id) {
			old_counter = __shfl((int)old_counter, leader_lid);
			if(sb_chunk_id(old_counter) != chunk_id)
				return_mask &= ~1;
			uint old_count = sb_count(old_counter);
			uint threshold = size_infos_g[size_id].busy_threshold;
			if(old_count < threshold && old_count + change >= threshold)
				return_mask |= 2;
		}
		want_inc = want_inc && sb_id != leader_sb_id;
	}  // while
	//return true;
	//return sb_size_id(old_counter) == size_id;
	return return_mask;
}  // sb_ctr_inc

/** increment the non-distributed counter of the superblock 
		sb_id id of the slab for which the counter is decremented
		alloc_sz allocation size decrement for the thread (in chunks)
 */
__device__ __forceinline__ void sb_ctr_dec(uint sb_id, uint nchunks) {
	bool want_inc = true;
	uint mask, lid = threadIdx.x % WARP_SZ;
	while(mask = __ballot(want_inc)) {
		uint leader_lid = warp_leader(mask), leader_sb_id = sb_id;
		leader_sb_id = __shfl((int)leader_sb_id, leader_lid);
		// allocation size is same for all superblocks
		// TODO: handle the situation when different allocation sizes are 
		// freed within the same slab, and do reduction for that
		uint change = nchunks * __popc(__ballot(sb_id == leader_sb_id));
		if(lid == leader_lid) {
			uint old_counter = sb_counter_dec(&sb_counters_g[sb_id], change);
			if(!sb_is_head(old_counter)) {
				uint size_id = sb_size_id(old_counter);
				uint chunk_id = sb_chunk_id(old_counter);
				// slab is non-head, so do manipulations
				uint old_count = sb_count(old_counter), new_count = old_count - change;
				uint threshold = size_infos_g[size_id].roomy_threshold;
				if(new_count <= threshold && old_count > threshold && new_count > 0) {
					// mark superblock as roomy for current size
					sbset_add_to(roomy_sbs_g[size_id], sb_id);
				} else if(new_count == 0) {
					sb_try_mark_free(sb_id, size_id, chunk_id, false);
				}  // if(slab position in sets changes)
				// }
			}  // if(not a head slab) 
		} // if(leader lane)
		want_inc = want_inc && sb_id != leader_sb_id;
	}  // while(any one wants to deallocate)
}  // sb_ctr_dec

/** finds a suitable new slab for size and just returns it, without modifying
		any of the underlying size data structures */
__device__ inline uint find_sb_for_size(uint size_id, uint chunk_id) {
	uint new_head = SB_NONE;
	// first try among roomy sb's of current size
	while((new_head = sbset_get_from(roomy_sbs_g[size_id])) != SB_NONE) {
		// try set head
		uint old_counter = atomicOr(&sb_counters_g[new_head], 1 << SB_HEAD_POS);
		if(sb_is_head(old_counter)) { 
		} else if(sb_size_id(old_counter) != size_id 
							|| sb_count(old_counter) > size_infos_g[size_id].roomy_threshold) {
			// drop the block and go for another
			// TODO: process this as another head detachment
			atomicAnd(&sb_counters_g[new_head], ~(1 << SB_HEAD_POS));
		} else
			break;
	}  // while(searching through new heads)
 
	// try getting from free superblocks; hear actually getting one 
	// always means success, as only truly free block get to this bit array
	if(new_head == SB_NONE) {
		new_head = sbset_get_from(free_sbs_g);
		if(new_head != SB_NONE) {
			// fill in the slab
			*(volatile uint *)&sbs_g[new_head].size_id = size_id;
			*(volatile uint *)&sbs_g[new_head].chunk_sz = 
				size_infos_g[size_id].chunk_sz;
			uint old_counter = sb_counter_val(0, false, SZ_NONE, SZ_NONE);
			uint new_counter = sb_counter_val(0, true, chunk_id, size_id);
			// there may be others trying to set the head; as they come from
			// roomy blocks, they will fail; also, there may be some ongoing
			// allocation attempts, so just wait
			while(atomicCAS(&sb_counters_g[new_head], old_counter, new_counter) !=
						old_counter);
			//atomicCAS(&sb_counters_g[new_head], old_counter, new_counter);
		}  // if(got new head from free slabs)
	}
	
	// try stealing head (with fully free counters only) from other sizes;
	// TODO: make it more reliable, i.e. do not miss locked sizes completely
#if 0
	if(new_head == SB_NONE) {
		for(uint jsize_id = 0; jsize_id < nsizes_g && new_head == SB_NONE;
				jsize_id++) {
			if(jsize_id == size_id)
				continue;
			// just jump over size ids we're unable to lock
			if(try_lock(&head_locks_g[0][jsize_id])) {
				// TODO: add jchunk_id into the equation
				// currently take fully free heads only
				uint old_counter = sb_counter_val(0, true, SZ_NONE, jsize_id);
				uint new_counter = sb_counter_val(0, true, SZ_NONE, size_id);
				uint head = *(volatile uint *)&cached_sbs_g[0][jsize_id];
				// TODO: reduce code duplication
				if(head != SB_NONE && 
					 atomicCAS(&sb_counters_g[head], old_counter, new_counter) ==
					 old_counter) {
					new_head = head;
					cached_sbs_g[0][jsize_id] = SB_NONE;
				} else {
					head = *(volatile uint *)&head_sbs_g[0][jsize_id];
					if(head != SB_NONE && 
						 atomicCAS(&sb_counters_g[head], old_counter, new_counter) ==
						 old_counter) {
						new_head = head;
						head_sbs_g[0][jsize_id] = SB_NONE;

					}
				}
				if(new_head != SB_NONE)
					__threadfence();
				unlock(&head_locks_g[0][jsize_id]);
			}  // if(locked head)
		}  // for(jsize_id)
	}
#endif
	return new_head;
	// TODO: request additional memory from CUDA allocator
}  // find_sb_for_size

/** tries to find a new superblock for the given size
		@returns the new head superblock id if found, and SB_NONE if none
		@remarks this function should be called by at most 1 thread in a warp at a time
*/
__device__ inline uint new_sb_for_size
(uint size_id, uint chunk_id, uint ihead) {
	// try locking size id
	// TODO: make those who failed to lock attempt to allocate
	// in what free space left there
	//uint64 t1 = clock64();
	uint cur_head = *(volatile uint *)&head_sbs_g[ihead][size_id];
	if(try_lock(&head_locks_g[ihead][size_id])) {
		// locked successfully, check if really need replacing blocks
		uint new_head = SB_NONE;
		uint roomy_threshold = size_infos_g[size_id].roomy_threshold;
		if(cur_head == SB_NONE || 
			 sb_count(*(volatile uint *)&sb_counters_g[cur_head]) >=
			 size_infos_g[size_id].busy_threshold) {
			
			new_head = cached_sbs_g[ihead][size_id];
			cached_sbs_g[ihead][size_id] = SB_NONE;
			// this can happen, e.g., on start
			if(new_head == SB_NONE)
				new_head = find_sb_for_size(size_id, chunk_id);

			if(new_head != SB_NONE) {
				// set the new head, so that allocations can continue
				head_sbs_g[ihead][size_id] = new_head;
				__threadfence();
				// detach current head
				if(cur_head != SB_NONE) {
					uint old_counter = atomicAnd(&sb_counters_g[cur_head], 
																			 ~(1 << SB_HEAD_POS));
					uint count = sb_count(old_counter);
					if(count == 0) {
						// very unlikely
						sb_try_mark_free(cur_head, size_id, chunk_id, true);
					} else if(count <= roomy_threshold) {
						// mark as roomy
						sbset_add_to(roomy_sbs_g[size_id], cur_head);
					} 
				}  // if(there's a head to detach)
				// cache a new head slab
				cached_sbs_g[ihead][size_id] = find_sb_for_size(size_id, chunk_id);
				__threadfence();
			}  // if(found new head)
		} else {
			// looks like we read stale data at some point, just re-read head
			new_head = *(volatile uint *)&head_sbs_g[ihead][size_id];
		}
		unlock(&head_locks_g[ihead][size_id]);
		//uint64 t2 = clock64();
		//printf("needed %lld cycles to find new head slab\n", t2 - t1);
		//printf("new head = %d\n", new_head);
		return new_head;
	} else {
		// someone else working on current head superblock; 
		while(true) {
			if(*(volatile uint *)&head_sbs_g[ihead][size_id] != cur_head ||
							 *(volatile uint *)&head_locks_g[ihead][size_id] == 0)
				//if(*(volatile uint *)&head_locks_g[ihead][size_id] == 0);
				break;
		}
		return *(volatile uint *)&head_sbs_g[ihead][size_id];
	}
}  // new_sb_for_size

	/** allocates memory inside the superblock 
			@param isb the superblock inside which to allocate
			@param [in,out] iblock the block from which to start searching
			@param size_id the size id for the allocation
			@returns the pointer to the allocated memory, or 0 if unable to allocate
	*/
__device__ __forceinline__ void *sb_alloc_in
(uint ihead, uint isb, uint &ichunk, size_info_t size_info, uint size_id,
 bool &needs_new_head) {
	if(isb == SB_NONE) {
		needs_new_head = true;
		return 0;
	}
	void *p = 0;
	uint *block_bits = sb_block_bits(isb);
	superblock_t sb = sbs_g[isb];
	uint nchunks = size_infos_g[size_id].nchunks_in_block;

	uint iword, ibit, old_word;
	bool reserved = false;
	// iterate until successfully reserved
	for(uint itry = 0; itry < MAX_NTRIES; itry++) {
		// try reserve
		iword = ichunk / WORD_SZ;
		ibit = ichunk % WORD_SZ;
		uint alloc_mask = ((1 << nchunks) - 1) << ibit;
		old_word = atomicOr(block_bits + iword, alloc_mask);
		if(!(old_word & alloc_mask)) {
			// initial reservation successful
			reserved = true;
			break;
		} else {
			if(~old_word & alloc_mask) {
				// memory was partially allocated, need to roll back
				atomicAnd(block_bits + iword, ~alloc_mask | (old_word & alloc_mask));
			}
			ichunk = (ichunk + size_info.hash_step) % size_info.nchunks;
			//ichunk = (ichunk + size_info.hash_step) & (size_info.nchunks - 1);
		}
	}
	if(reserved) {
		// increment counter
		uint inc_mask = sb_ctr_inc
			(size_id, size_info.chunk_id, isb, nchunks);
			//if(!sb_ctr_inc(size_id, isb, 1)) {
		if(!(inc_mask & 1)) {
			// reservation unsuccessful (slab was freed), cancel it
			sb_counter_dec(&sb_counters_g[isb], nchunks);
			//atomicAnd(block_bits + iword, ~(1 << ibit));
			uint alloc_mask = ((1 << nchunks) - 1) << ibit;
			atomicAnd(block_bits + iword, ~alloc_mask | (old_word & alloc_mask));
			reserved = false;
		} else if(inc_mask & 2)
			needs_new_head = true;
	}
	if(reserved) {
		p = (char *)sb.ptr + ichunk * size_info.chunk_sz;
		// write allocation size
		// TODO: support chunks of other size
		uint *alloc_sizes = sb_alloc_sizes(isb);
		sb_set_alloc_size(alloc_sizes, ichunk, nchunks);
	} else
		needs_new_head = true;
	return p;
}  // sb_alloc_in
