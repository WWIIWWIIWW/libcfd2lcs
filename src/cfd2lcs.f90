!Top level, user interface module.
subroutine cfd2lcs_init(cfdcomm,n,offset,x,y,z,BC_LIST,lperiodic)
	use sgrid_m
	implicit none
	!----
	integer(LCSIP):: cfdcomm
	integer(LCSIP):: n(3),offset(3)
	real(LCSRP):: x(1:n(1),1:n(2),1:n(3))
	real(LCSRP):: y(1:n(1),1:n(2),1:n(3))
	real(LCSRP):: z(1:n(1),1:n(2),1:n(3))
	integer(LCSIP),dimension(6):: BC_LIST
	real(LCSRP):: lperiodic(3)
	!----
	integer,pointer:: ni,nj,nk,ng
	integer:: error,success1,success2
	!----

	!Error handling:
	CFD2LCS_ERROR = 0

	!Initialize data counters
	NLCS = 0
	NLP = 0
	NSGRID = 0

	!init the mpi
	call init_lcs_mpi(cfdcomm)

	if(lcsrank ==0)&
		write(*,*) 'in cfd2lcs_init...'

	!Init the default structured cfd storage (scfd) :
	scfd%label = 'CDF DATA'
	call init_sgrid(scfd%sgrid,'CFD GRID',n,offset,x,y,z,BC_LIST,lperiodic)
	call init_sr1(scfd%u_n,scfd%sgrid%ni,scfd%sgrid%nj,scfd%sgrid%nk,scfd%sgrid%ng,'U_N',translate=.false.)
	call init_sr1(scfd%u_np1,scfd%sgrid%ni,scfd%sgrid%nj,scfd%sgrid%nk,scfd%sgrid%ng,'U_NP1',translate=.false.)

	!TODO:  Add a check here to see if you can use the bspline interp
	!or if you need the RBF interp for non-rectilinear grids.


	!Make sure the required output and tmp directories exist
	if(lcsrank ==0) then
		call system("mkdir -p ./"//trim(OUTPUT_DIR), success1)
		call system("mkdir -p ./"//trim(TEMP_DIR), success2)
		if (success1 /= 0 .OR. success2 /=0) then
			write(*,*) 'ERROR:  cfd2lcs cannot create required output directories'
			CFD2LCS_ERROR = 1
		endif
	endif


	!Check:
	call cfd2lcs_error_check(error)
end subroutine cfd2lcs_init

subroutine cfd2lcs_update(n,ux,uy,uz,time)
	use data_m
	use io_m
	use comms_m
	use sgrid_m
	use lp_motion_m
	use lcs_m
	use lp_m
	use flowmap_m
	implicit none
	!----
	integer:: n(3)
	real(LCSRP):: ux(1:n(1),1:n(2),1:n(3))
	real(LCSRP):: uy(1:n(1),1:n(2),1:n(3))
	real(LCSRP):: uz(1:n(1),1:n(2),1:n(3))
	real(LCSRP), intent(in):: time
	!----
	integer:: gn(3)
	integer:: offset(3)
	integer:: error
	integer:: ilp,ilcs
	type(lp_t),pointer:: lp
	type(lcs_t),pointer:: lcs
	logical,save:: FIRST_CALL = .true.
	!----
	if(CFD2LCS_ERROR /= 0) return

	if(lcsrank ==0)&
		write(*,*) 'in cfd2lcs_update...'

	!Check we got an arrays of the correct size:
	if	( scfd%sgrid%ni/=n(1) .OR. scfd%sgrid%nj /= n(2) .OR. scfd%sgrid%nk /=n(3)) then
		write(*,'(a,i6,a)') 'rank[',lcsrank,'] received velocity array of incorrect dimension'
		write(*,'(a,i6,a,i4,i4,i4,a)') 'rank[',lcsrank,'] [ni,nj,nk]= [',n(1),n(2),n(3),']'
		write(*,'(a,i6,a,i4,i4,i4,a)') 'rank[',lcsrank,'] sgrid[ni,nj,nk]= [',scfd%sgrid%ni,scfd%sgrid%nj,scfd%sgrid%nk,']'
		CFD2LCS_ERROR = 1
		return
	endif

	!Set the new velocity, update ghosts and fakes:
	if(FIRST_CALL) then
		scfd%t_n = time  !allows us to not start at t=0
		scfd%t_np1 = time  !allows us to not start at t=0
		FIRST_CALL = .FALSE.
	else
		scfd%t_n = scfd%t_np1
		scfd%t_np1 = time
	endif
	scfd%u_n = scfd%u_np1  !Shift down the velocity field from np1 => n
	scfd%u_np1%x(1:n(1),1:n(2),1:n(3)) = ux(1:n(1),1:n(2),1:n(3))
	scfd%u_np1%y(1:n(1),1:n(2),1:n(3)) = uy(1:n(1),1:n(2),1:n(3))
	scfd%u_np1%z(1:n(1),1:n(2),1:n(3)) = uz(1:n(1),1:n(2),1:n(3))
	call exchange_sdata(scfd%sgrid%scomm_max_r1,r1=scfd%u_np1)
	call set_velocity_bc(scfd%sgrid%bc_list,scfd%u_np1)

	!-----
	! Update each (forward-time) LP set:
	!-----
	do ilp = 1, NLP
		lp => lp_c(ilp)
		if(lp%direction == FWD) then
			call update_lp(lp,scfd)
		endif
	enddo

	!-----
	! Update each lcs diagnostic:
	!-----
	do ilcs = 1, NLCS
		lcs => lcs_c(ilcs)

		!-----
		!For any backward time diagnostics,
		!update the semi-lagrangian fields:
		!-----
		select case(lcs%diagnostic)
			case (FTLE_BKWD)
				call update_flowmap_sl(lcs,scfd)
			case default
		end select

		!-----
		!Check if this timestep corresponds to a flowmap substep inerval
		!If yes, then update all the data
		!-----
		if( int(scfd%t_np1/lcs%h) /= int(scfd%t_n/lcs%h) ) then

			!-----
			!Map the forward time particle back to their original grid:
			!-----
			select case(lcs%diagnostic)
			case (FTLE_FWD)
				call exchange_lpmap(lcs%lp,lcs%fm)
			case default
			end select

			!-----
			!Write temp files for the flow map substep
			!-----
			call write_flowmap_substep(lcs)

			!-----
			!Reconstruct the time T flowmap from time h substeps
			!-----
			call reconstruct_flowmap(lcs)

			!-----
			!Compute the FTLE
			!-----
			select case(lcs%diagnostic)
			case (FTLE_FWD,FTLE_BKWD)
					call compute_ftle(lcs)
			case default
			end select

			!-----
			!Write the time T LCS
			!-----
			call write_lcs(lcs,scfd%t_np1)

			!-----
			!Reset the flow maps for FTLE type diagnostics
			!-----
			select case(lcs%diagnostic)
				case(FTLE_FWD)
					if(lcsrank ==0)&
						write(*,*) 'Resetting flow map for:  Name: ',(lcs%label)
					call reset_lp(lcs%lp,lcs%sgrid%grid)
					call track_lp2node(lcs%lp,scfd%sgrid) !Track lp to the cfd grid
				case(FTLE_BKWD)
					if(lcsrank ==0)&
						write(*,*) 'Resetting flow map for:  Name: ',(lcs%label)
					lcs%fm%x = 0.0_LCSRP
					lcs%fm%y = 0.0_LCSRP
					lcs%fm%z = 0.0_LCSRP
					call reset_lp(lcs%lp,lcs%sgrid%grid)
					call track_lp2node(lcs%lp,lcs%sgrid) !Track lp to the lcs grid
				case default
			end select

		endif

	enddo

	!Check
	call cfd2lcs_error_check(error)

end subroutine cfd2lcs_update

subroutine cfd2lcs_diagnostic_init(lcs_handle,lcs_type,resolution,T,h,rhop,dp,label)
	use data_m
	use sgrid_m
	use lp_m
	use lp_tracking_m
	implicit none
	!----
	integer(LCSIP),intent(out):: lcs_handle
	integer(LCSIP),intent(in):: lcs_type
	integer(LCSIP),intent(in):: resolution
	real(LCSRP),intent(in):: T
	real(LCSRP),intent(in):: h
	real(LCSRP):: rhop
	real(LCSRP):: dp
	character(len=*),intent(in):: label
	!----
	type(lcs_t),allocatable:: lcs_c_tmp(:)
	type(lcs_t),pointer:: lcs
	integer:: error
	integer,allocatable:: sgridptr(:),lpptr(:)
	integer:: isg,ilp,ilcs,np,ip
	!----
	!Initialize an lcs diagnostic.  Re-use the flow maps/tracer advections
	!from other diagnostics if possible.
	!Allow the user to increase/decrease the resolution from the scfd data.
	!----

	if(lcsrank ==0)&
		write(*,*) 'in cfd2lcs_diagnostic_init... ',trim(label)

	!----
	!Add a new item to the lcs array
	!Careful to preserve ptrs to lp and sgrid
	!----
	if(NLCS == 0 ) then
		NLCS = NLCS + 1
		allocate(lcs_c(NLCS))
	else
		!save existing ptrs
		allocate(sgridptr(1:NLCS))
		allocate(lpptr(1:NLCS))
		sgridptr = -1
		lpptr = -1
		do ilcs = 1,NLCS
			if (associated(lcs_c(ilcs)%sgrid,scfd%sgrid)) then
				sgridptr(ilcs) = 0
			endif
			do isg = 1,NSGRID
				if (associated(lcs_c(ilcs)%sgrid,sgrid_c(isg))) then
					sgridptr(ilcs) = isg
				endif
			enddo
			do ilp = 1,NLP
				if (associated(lcs_c(ilcs)%lp,lp_c(ilp))) then
					lpptr(ilcs) = ilp
				endif
			enddo
		enddo

		!expand array of structures
		allocate(lcs_c_tmp(NLCS))
		lcs_c_tmp = lcs_c
		deallocate(lcs_c)
		allocate(lcs_c(NLCS+1))
		lcs_c(1:NLCS) = lcs_c_tmp(1:NLCS)

		!fix old ptrs
		do ilcs = 1,NLCS
			if(sgridptr(ilcs) == 0) then
				lcs_c(ilcs)%sgrid => scfd%sgrid
			endif
			if(sgridptr(ilcs) > 0) then
				lcs_c(ilcs)%sgrid => sgrid_c(sgridptr(ilcs))
			endif
			if(lpptr(ilcs) > 0) then
				lcs_c(ilcs)%lp => lp_c(lpptr(ilcs))
			endif
		enddo

		NLCS = NLCS + 1
	endif

	!-----
	!Point to the new lcs and set this up
	!-----
	lcs => lcs_c(NLCS)
	lcs%id = NLCS
	lcs%diagnostic = lcs_type
	lcs%label = trim(label)
	lcs%T = T
	lcs%h = h

	!-----
	!Define the grid for this LCS diagnostic
	!-----
	lcs%resolution = resolution  !cant modify "resolution" because it comes from user side.
	if(lcs%resolution == 0) then
		!We are using the CFD grid for the LCS calculations
		if(lcsrank ==0)&
			write(*,*) 'Using Native CFD grid'
		lcs%sgrid => scfd%sgrid
	else
		!Add/Remove gride points from existing CFD grid:
		if(lcsrank ==0)&
			write(*,*) 'New Grid with resolution factor',lcs%resolution
		call new_sgrid_from_sgrid(lcs%sgrid,scfd%sgrid,trim(lcs%label)//'-grid',lcs%resolution)
	endif

	!-----
	!Figure out what we are dealing with and initialize appropriately:
	!-----
	select case(lcs%diagnostic)
		case(FTLE_FWD)
			if(lcsrank ==0)&
				write(*,*) 'FWD Time FTLE:  Name: ',(lcs%label)
			call init_sr1(lcs%fm,lcs%sgrid%ni,lcs%sgrid%nj,lcs%sgrid%nk,lcs%sgrid%ng,'FWD-FM',translate=.false.)
			call init_sr0(lcs%ftle,lcs%sgrid%ni,lcs%sgrid%nj,lcs%sgrid%nk,lcs%sgrid%ng,'FWD-FTLE')
			call init_lp(lcs%lp,trim(label)//'-particles',rhop,dp,lcs%sgrid%grid,FWD)
			call track_lp2node(lcs%lp,scfd%sgrid) !Track lp to the cfd grid

		case(FTLE_BKWD)
			if(lcsrank ==0)&
				write(*,*) 'BKWD Time FTLE:  Name: ',(lcs%label)
			call init_sr1(lcs%fm,lcs%sgrid%ni,lcs%sgrid%nj,lcs%sgrid%nk,lcs%sgrid%ng,'BKWD-FM',translate=.false.) !fm set to zero
			call init_sr0(lcs%ftle,lcs%sgrid%ni,lcs%sgrid%nj,lcs%sgrid%nk,lcs%sgrid%ng,'BKWD-FTLE')
			call init_lp(lcs%lp,trim(label)//'-particles',rhop,dp,lcs%sgrid%grid,BKWD)
			!Find and save the nearest scfd node
			call init_ui1(lcs%scfd_node,lcs%lp%np,'CFD_NODE') 
			call track_lp2node(lcs%lp,scfd%sgrid)
			lcs%scfd_node%x(1:lcs%lp%np) = lcs%lp%no%x(1:lcs%lp%np)
			lcs%scfd_node%y(1:lcs%lp%np) = lcs%lp%no%y(1:lcs%lp%np)
			lcs%scfd_node%z(1:lcs%lp%np) = lcs%lp%no%z(1:lcs%lp%np)
			!Now, reset index to the lcs grid
			call reset_lp(lcs%lp,lcs%sgrid%grid)  
		
		case(LP_TRACER)
			if(lcsrank ==0)&
				write(*,*) 'Lagrangian Particle Tracers::  Name: ',(lcs%label)
			call init_lp(lcs%lp,trim(label)//'-particles',rhop,dp,lcs%sgrid%grid,FWD)
			call track_lp2node(lcs%lp,scfd%sgrid) !Track lp to the cfd grid

		case default
			if(lcsrank ==0)&
				write(*,'(a)') 'ERROR, bad specification for lcs_type.&
					& Options are: FTLE_FWD, FTLE_BKWD, FTLE_FWD_BKWD'
			CFD2LCS_ERROR = 1
	end select

	!-----
	!Check ptr association for LCS
	!-----
	do ilcs = 1,NLCS
		if(.NOT. associated(lcs_c(ilcs)%sgrid)) then
			write(*,*)'lcsrank[',lcsrank,'] ERROR:  lcs%sgrid not associated for lcs #',ilcs,trim(lcs_c(ilcs)%label)
			CFD2LCS_ERROR = 1
		endif
		if(lcs_c(ilcs)%diagnostic == FTLE_BKWD) cycle  !no lp
		if(.NOT. associated(lcs_c(ilcs)%lp)) then
			write(*,*)'lcsrank[',lcsrank,'] ERROR:  lcs%lp not associated for lcs #',ilcs,trim(lcs_c(ilcs)%label)
			CFD2LCS_ERROR = 1
		endif
	enddo

	!-----
	!Pass back the id in lcs_handle
	!-----
	lcs_handle = lcs%id

	call cfd2lcs_error_check(error)

end subroutine cfd2lcs_diagnostic_init

subroutine cfd2lcs_diagnostic_destroy(lcs_handle)
	use data_m
	implicit none
	!-----
	integer:: lcs_handle
	!-----

	!TODO:  Allow the user to destroy a LCS diagnostic by passing it's integer handle

end subroutine cfd2lcs_diagnostic_destroy

subroutine cfd2lcs_finalize()
	use data_m
	use sgrid_m
	implicit none
	!-----
	integer:: idata
	!-----

	if(lcsrank ==0)&
		write(*,'(a)') 'in cfd2lcs_finalize...'

	!Deallocate all LCS

	!Deallocate all lp

	!Deallocate all sgrid and nullify pointers
	do idata = 1,NSGRID
		call destroy_sgrid(sgrid_c(idata))
	enddo

	!Cleanup scfd
	call destroy_sr1(scfd%u_n)
	call destroy_sr1(scfd%u_np1)
	scfd%label = 'Unused CFD data'

end subroutine cfd2lcs_finalize

subroutine cfd2lcs_error_check(error)
	use data_m
	implicit none
	!-----
	integer:: error
	integer:: ierr,MAX_CFD2LCS_ERROR
	!-----
	!In the event of a cfd2lcs error, we dont necessarily want
	!to bring down the cfd solver.  So, flag an error instead:
	!-----
	error= 0
	call MPI_ALLREDUCE(CFD2LCS_ERROR,MAX_CFD2LCS_ERROR,1,MPI_INTEGER,MPI_SUM,lcscomm,ierr)
	if (MAX_CFD2LCS_ERROR /= 0) then
		if (lcsrank==0) write(*,'(a)') &
			'FATAL CFD2LCS_ERROR DETECTED, WILL NOT PERFORM LCS COMPUTATIONS'
		CFD2LCS_ERROR = 1
		error = 1
	endif
end subroutine cfd2lcs_error_check




!		ind = nint(scfd%t_np1/lcs%h)
!if( abs(real(ind)*lcs%h-scfd%t_np1) < 0.51*(scfd%t_np1-scfd%t_n)) hstep = .true.
		!if( abs(mod(scfd%t_np1,lcs%h)) <= 0.51*(scfd%t_np1-scfd%t_n)) hstep = .true.
