!
! Data structure definitions
!
module data_m
	implicit none
	INCLUDE 'cfd2lcs_f.h'

	!Some constants:
	integer,parameter:: MAX_NAMELEN = 32
	integer,parameter:: NGHOST_CFD = 3

	!Real, structured rank 0 scalar (sr0_t)
	type sr0_t
		integer:: ni,nj,nk,ng
		character(len=MAX_NAMELEN):: label
		real(LCSRP), allocatable:: r(:,:,:)
	end type sr0_t

	!Real, structured Cartesian rank 1 vector (sr1_t)
	type sr1_t
		integer:: ni,nj,nk,ng
		character(len=MAX_NAMELEN):: label
		real(LCSRP), allocatable:: x(:,:,:)
		real(LCSRP), allocatable:: y(:,:,:)
		real(LCSRP), allocatable:: z(:,:,:)
	end type sr1_t

	!Real, structured Cartesian rank 2 tensor (sr2_t)
	type sr2_t
		integer:: ni,nj,nk,ng
		character(len=MAX_NAMELEN):: label
		real(LCSRP), allocatable:: xx(:,:,:)
		real(LCSRP), allocatable:: xy(:,:,:)
		real(LCSRP), allocatable:: xz(:,:,:)
		real(LCSRP), allocatable:: yx(:,:,:)
		real(LCSRP), allocatable:: yy(:,:,:)
		real(LCSRP), allocatable:: yz(:,:,:)
		real(LCSRP), allocatable:: zx(:,:,:)
		real(LCSRP), allocatable:: zy(:,:,:)
		real(LCSRP), allocatable:: zz(:,:,:)
	end type sr2_t

	!Structured Comms (scomm_t):
	type scomm_t
		character(len=MAX_NAMELEN):: label
		integer:: connectivity !Either FACE_CONN or MAX_CONN
		integer :: nbr_rank(-1:1,-1:1,-1:1) !Rank of processor in each direction
		integer :: flag(-1:1,-1:1,-1:1) !tells us what to do in each direction
		integer :: checker(-1:1,-1:1,-1:1) !Checkerboard pattern for each comm direction
		integer :: n_pack(-1:1,-1:1,-1:1), n_unpack(-1:1,-1:1,-1:1)  !Number of pack/unpack elements in each dir
		integer :: pack_list_min(-1:1,-1:1,-1:1,1:3),pack_list_max(-1:1,-1:1,-1:1,1:3) !Range for packing buffers
		integer :: unpack_list_min(-1:1,-1:1,-1:1,1:3),unpack_list_max(-1:1,-1:1,-1:1,1:3) !Range for packing buffers
		real(LCSRP), allocatable :: pack_buffer(:), unpack_buffer(:)  !Exchange buffers
	end type scomm_t

	!Structured CFD data (scfd_t):
	type scfd_t
		character(len=MAX_NAMELEN):: label

		!Dimensions
		integer:: ni, nj, nk, ng
		integer:: gni, gnj, gnk
		integer:: offset_i, offset_j, offset_k

		!Communicators
		type(scomm_t):: scomm_face
		type(scomm_t):: scomm_max

		!Data
		type(sr1_t):: grid  !Cartesian grid coordinates
		type(sr1_t):: u		!Current velocity field

	end type scfd_t

	!The CFD side data:
	type(scfd_t):: scfd

	!Error handling:
	integer:: CFD2LCS_ERROR

end module data_m
